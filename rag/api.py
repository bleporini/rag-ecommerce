#!/usr/bin/env python
import os

import chromadb
from fastapi import FastAPI
from langchain.chat_models import ChatOpenAI
from langchain.prompts import ChatPromptTemplate
from langchain_chroma import Chroma
from langchain_core.output_parsers import StrOutputParser
from langchain_openai import OpenAIEmbeddings
from langserve import add_routes
from langchain_core.runnables import RunnablePassthrough


app = FastAPI(
    title="LangChain Server",
    version="1.0",
    description="A simple api server using Langchain's Runnable interfaces",
)
embeddings = OpenAIEmbeddings(model="text-embedding-3-large")

client = chromadb.HttpClient(host=os.environ['CHROMA_HOST'], port=8000)
vstore = Chroma(
    client=client,
    collection_name="products",
    embedding_function=embeddings
)

parser = StrOutputParser()
retriever = vstore.as_retriever()
template = """As an assistant to an ecommerce shop, answer the question asked by a visitor based only on the following context:
{context}
If the question is about a product, you should find the url in the metadata of each element of the context, then provide this url in your answer.
If you find options from the context that are irrelevant, you shall filter it out.
Question: {question}
"""

prompt = ChatPromptTemplate.from_template(template)
model = ChatOpenAI(temperature=0, model="gpt-4")
chain = (
        {"context": retriever, "question": RunnablePassthrough()}
        | prompt
        | model
        | StrOutputParser()
)

add_routes(
    app,
    chain,
    path="/chat",
)


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8001)