import asyncio
import json
import os
import sys
from typing import Dict, AsyncGenerator, Any, List

from fastapi import FastAPI, Request, HTTPException, status
from fastapi.responses import JSONResponse
from confluent_kafka import Producer, KafkaException
from confluent_kafka.schema_registry import SchemaRegistryClient
from confluent_kafka.schema_registry.avro import AvroSerializer
from confluent_kafka.serialization import SerializationContext, MessageField
from sse_starlette.sse import EventSourceResponse

# --- Avro Schemas ---
KEY_SCHEMA_STR = """
{
  "fields": [
    {
      "name": "key",
      "type": "string"
    }
  ],
  "name": "customer_conversations_key",
  "namespace": "org.apache.flink.avro.generated.record",
  "type": "record"
}
"""

VALUE_SCHEMA_STR = """
{
  "fields": [
    {
      "default": null,
      "name": "input",
      "type": [
        "null",
        "string"
      ]
    },
    {
      "default": null,
      "name": "callback_url",
      "type": [
        "null",
        "string"
      ]
    }
  ],
  "name": "customer_conversations_value",
  "namespace": "org.apache.flink.avro.generated.record",
  "type": "record"
}
"""

# --- Helper function to read configuration ---
def read_config(file):
    """Reads client configuration from a properties file and returns it as a key-value map."""
    config = {}
    try:
        with open(file) as fh:
            for line in fh:
                line = line.strip()
                if len(line) != 0 and line[0] != "#":
                    parameter, value = line.strip().split('=', 1)
                    config[parameter] = value.strip()
        print(f"Config loaded from {file}:")
        print(config)
        sys.stdout.flush()
    except FileNotFoundError:
        print(f"Warning: Configuration file '{file}' not found. Using default settings.")
        if 'sr' not in file:
             config['bootstrap.servers'] = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "localhost:9092")
    return config

# --- Kafka Producer Class ---
class KafkaProducerManager:
    """
    Manages the lifecycle and operations of a Confluent Kafka Producer with Avro serialization.
    """
    def __init__(self, config_file: str, sr_config_file: str, topic: str):
        print("Loading Kafka configuration...")
        producer_conf = read_config(config_file)
        sr_conf = read_config(sr_config_file)

        print("Initializing Schema Registry and Avro serializers...")
        schema_registry_client = SchemaRegistryClient(sr_conf)
        self._key_serializer = AvroSerializer(schema_registry_client, KEY_SCHEMA_STR)
        self._value_serializer = AvroSerializer(schema_registry_client, VALUE_SCHEMA_STR)

        self._producer = Producer(producer_conf)
        self._topic = topic
        print("Kafka producer created.")

    async def send_message_async(self, key: Dict, value: Dict):
        """
        Serializes and asynchronously sends a message to the configured Kafka topic.
        """
        loop = asyncio.get_event_loop()
        future = loop.create_future()

        def delivery_callback(err, msg):
            if err is not None:
                loop.call_soon_threadsafe(future.set_exception, KafkaException(err))
            else:
                loop.call_soon_threadsafe(future.set_result, msg)

        try:
            key_bytes = self._key_serializer(key, SerializationContext(self._topic, MessageField.KEY))
            value_bytes = self._value_serializer(value, SerializationContext(self._topic, MessageField.VALUE))

            self._producer.produce(
                topic=self._topic,
                key=key_bytes,
                value=value_bytes,
                callback=delivery_callback
            )
            self._producer.poll(1)
            await future
        except Exception as e:
            print(f"Kafka: Error during serialization or production: {e}")
            raise

    def flush(self):
        """Flushes any outstanding messages in the producer's queue."""
        if self._producer:
            print("Flushing Kafka producer.")
            self._producer.flush()
            print("Kafka producer flushed.")

# --- FastAPI App Setup ---
app = FastAPI(
    title="RAG Chat API",
    description="API for handling customer text inputs via SSE, forwarding to Kafka, and pushing LLM answers back via SSE.",
    version="1.0.0",
)

# --- Middleware for Debugging ---
@app.middleware("http")
async def debug_log_request_body(request: Request, call_next):
    # Log headers
    print("--- Request Headers ---")
    for name, value in request.headers.items():
        print(f"{name}: {value}")
    print("-----------------------")

    # Log body
    body = await request.body()
    print(f"Request Body: {body.decode()}")

    # This is a workaround to allow the endpoint to read the body again,
    # as the body stream can only be read once.
    async def receive():
        return {"type": "http.request", "body": body}
    
    # Create a new Request object with the body, as the original body stream is consumed
    new_request = Request(request.scope, receive)
    
    response = await call_next(new_request)
    return response

# --- Configuration ---
CUSTOMER_QUESTIONS_TOPIC = os.getenv("CUSTOMER_QUESTIONS_TOPIC", "customer_questions")

# --- Global State ---
active_connections: Dict[str, asyncio.Queue] = {}
kafka_manager: KafkaProducerManager = None

# --- FastAPI Lifecycle Events ---
@app.on_event("startup")
async def startup_event():
    global kafka_manager
    kafka_manager = KafkaProducerManager(
        config_file="client.properties",
        sr_config_file="sr.properties",
        topic=CUSTOMER_QUESTIONS_TOPIC
    )

@app.on_event("shutdown")
async def shutdown_event():
    if kafka_manager:
        kafka_manager.flush()

# --- SSE Connection Manager ---
async def sse_event_generator(discussion_id: str) -> AsyncGenerator[Any, None]:
    """Generator for Server-Sent Events."""
    queue = active_connections.get(discussion_id)
    if not queue:
        return
    try:
        while True:
            message = await queue.get()
            if message is None: break
            yield message
    except asyncio.CancelledError:
        print(f"SSE: Client {discussion_id} disconnected (cancelled).")
    finally:
        if discussion_id in active_connections:
            del active_connections[discussion_id]
            print(f"SSE: Cleaned up connection for {discussion_id}.")

# --- Endpoints ---

@app.get("/chat/{discussion_id}", summary="Establish SSE connection for chat updates")
async def chat_sse_endpoint(discussion_id: str, request: Request):
    """Establishes a Server-Sent Events (SSE) connection for a given discussion_id."""
    if discussion_id in active_connections:
        print(f"SSE: Client reconnected for discussion_id: {discussion_id}. Replacing old queue.")
        old_queue = active_connections.get(discussion_id)
        if old_queue and not old_queue.empty():
            await old_queue.put(None)
        await asyncio.sleep(0.1)

    queue = asyncio.Queue()
    active_connections[discussion_id] = queue
    print(f"SSE: Client {discussion_id} connected. Active connections: {len(active_connections)}")
    return EventSourceResponse(sse_event_generator(discussion_id), media_type="text/event-stream")

@app.post("/questions/{discussion_id}", summary="Submit customer text input to Kafka")
async def submit_question(discussion_id: str, question_data: Dict[str, Any]):
    """
    Receives customer text input, formats it for Avro, and forwards to Kafka.
    """
    if not kafka_manager:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="Kafka manager not available.")

    # Construct key and value dictionaries matching the Avro schemas
    key_to_serialize = {"key": discussion_id}
    value_to_serialize = {
        "input": question_data.get("text", ""),
        "callback_url": f"/answers/{discussion_id}" # Set dynamic callback URL
    }

    try:
        await kafka_manager.send_message_async(
            key=key_to_serialize,
            value=value_to_serialize
        )
        print(f"Kafka: Avro question for {discussion_id} sent to {CUSTOMER_QUESTIONS_TOPIC}.")
        return JSONResponse(status_code=status.HTTP_202_ACCEPTED, content={"message": "Question accepted for processing."})
    except Exception as e:
        print(f"Kafka: Failed to queue Avro message for {discussion_id}: {e}")
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=f"Failed to queue message for Kafka: {e}")

@app.post("/answers/{discussion_id}", summary="Receive LLM answer and propagate to SSE channel")
async def receive_llm_answer(discussion_id: str, answer_payload: List[Dict[str, Any]]):
    """Receives an answer from the LLM and pushes it to the corresponding SSE channel."""
    if not answer_payload:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Request body cannot be an empty list.")

    answer_data = answer_payload[0]

    queue = active_connections.get(discussion_id)
    if not queue:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="No active SSE connection for this discussion ID.")

    try:
        await queue.put(answer_data['response'])
        print(f"LLM Answer: Answer for {discussion_id} pushed to SSE queue.")
        return JSONResponse(status_code=status.HTTP_200_OK, content={"message": "Answer propagated to SSE channel."})
    except Exception as e:
        print(f"LLM Answer: Failed to push answer to queue for {discussion_id}: {e}")
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=f"Failed to propagate answer: {e}")

# --- Health Check ---
@app.get("/health", summary="Health check endpoint")
async def health_check():
    return {"status": "ok", "kafka_manager_initialized": kafka_manager is not None}
