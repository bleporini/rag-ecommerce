from langchain_openai import OpenAIEmbeddings

embeddings = OpenAIEmbeddings(model="text-embedding-3-large")

vector= embeddings.embed_query("can you sell cups to dring coffee?")

print(vector)
