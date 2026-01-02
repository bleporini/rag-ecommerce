
provider "mongodbatlas" {
  public_key  = var.mongodb_atlas_public_key
  private_key = var.mongodb_atlas_private_key
}

resource "mongodbatlas_project" "vector_search_project" {
  name   = "ecommerce RAG"
  org_id = var.mongodb_org_id
}

/*
resource "mongodbatlas_cluster" "commerce" {
  project_id = mongodbatlas_project.vector_search_project.id
  name       = "commerce"
  provider_name = "TENANT"
  backing_provider_name = "AWS"
  provider_region_name = "eu-west-1"
  provider_instance_size_name = "M0"
  backup_enabled              = false
  auto_scaling_disk_gb_enabled = false
}
*/

resource "mongodbatlas_advanced_cluster" "commerce" {
  project_id = mongodbatlas_project.vector_search_project.id
  name       = "commerce"
  cluster_type = "REPLICASET"

  replication_specs = [
    {
      region_configs = [
        {
          electable_specs = {
            instance_size = "M0"
          }
          provider_name         = "TENANT"
          backing_provider_name = "AWS"
          region_name           = "EU_WEST_1"
          priority              = 7
        }
      ]
    }
  ]
}

resource "mongodbatlas_database_user" "rag_app_user" {
  project_id         = mongodbatlas_project.vector_search_project.id
  username           = "rag-app-user"
  password           = var.db_password
  auth_database_name = "admin"

  roles {
    role_name     = "readWrite"
    database_name = "ecommerce" # Grant readWrite access to the 'ecommerce' database
  }
}

resource "mongodbatlas_project_ip_access_list" "my_ip" {
  project_id = mongodbatlas_project.vector_search_project.id
  cidr_block = "0.0.0.0/0"
  comment    = "Allow access from anywhere for demo purposes."
}

# Use a provisioner with DOCKER to create the collection
resource "null_resource" "collection_creator" {
  depends_on = [
    mongodbatlas_project_ip_access_list.my_ip
  ]

  provisioner "local-exec" {
    # This command now runs mongosh from the official 'mongo' Docker image,
    # using the existing 'rag-app-user'.
    command = <<-EOT
      sleep 15
      docker run --rm mongo mongosh \
      "${mongodbatlas_advanced_cluster.commerce.connection_strings.standard_srv}" \
      --username ${mongodbatlas_database_user.rag_app_user.username} \
      --password '${var.db_password}' \
      --eval "db.getSiblingDB('ecommerce').getCollection('products_embedding').insertOne({_id: 'init_doc'}); db.getSiblingDB('ecommerce').getCollection('products_embedding').deleteOne({_id: 'init_doc'});"
    EOT
  }
}
resource "mongodbatlas_search_index" "product_vector_index" {
  depends_on = [
    null_resource.collection_creator
  ]
  type            = "vectorSearch"
  project_id      = mongodbatlas_project.vector_search_project.id
  cluster_name    = mongodbatlas_advanced_cluster.commerce.name
  name            = "idx_vector_description"
  database        = "ecommerce"
  collection_name = "products_embedding"

  fields = <<-EOT
    [{
      "numDimensions": 3072,
      "path": "description_embedding",
      "similarity": "cosine",
      "type": "vector"
    },
    {
      "path": "key",
      "type": "filter"
    },
    {
      "path": "description",
      "type": "filter"
    }]
  EOT
}