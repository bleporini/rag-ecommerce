import chromadb
import os
from langchain_openai import OpenAIEmbeddings
from chromadb.utils.embedding_functions import create_langchain_embedding



client = chromadb.HttpClient(host='localhost', port=8000)

os.environ["OPENAI_API_KEY"] = "sk-QBLaOUFSxtaubjsh1HLSjBMQMesMdDQQCDLbbXu7x2T3BlbkFJAPIpM7xN84BuMZDnLPtpgqTwbsiiHVwH7Hw0rqhtYA"
embeddings = OpenAIEmbeddings(model="text-embedding-3-large")

collection = client.get_collection("products", embedding_function=create_langchain_embedding(embeddings))



#query = collection.query(query_texts="I am looking for a mug",embeddings=create_langchain_embedding(embeddings))

#print(query)

collection.upsert(
    ids=['test'],
    metadatas=[{'stock': '10'}]
)