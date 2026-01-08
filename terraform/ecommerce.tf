# Configure the Confluent Provider
terraform {
  required_providers {
    confluent = {
      source  = "confluentinc/confluent"
      version = "2.51.0"
    }
    mongodbatlas = {
      source  = "mongodb/mongodbatlas"
      version = "2.1.0"
    }

  }
}

provider "confluent" {
  cloud_api_key    = var.confluent_cloud_api_key    # optionally use CONFLUENT_CLOUD_API_KEY env var
  cloud_api_secret = var.confluent_cloud_api_secret # optionally use CONFLUENT_CLOUD_API_SECRET env var
}

resource "confluent_environment" "ecommerce" {
  display_name = "ecommerce_${random_id.id.id}"

  stream_governance {
    package = "ADVANCED"
  }
}

data "confluent_schema_registry_cluster" "sr" {
  environment {
    id = confluent_environment.ecommerce.id
  }
  depends_on = [
    confluent_kafka_cluster.basic
  ]
}

resource "confluent_kafka_cluster" "basic" {
  display_name = "ecommerce-poc"
  availability = "SINGLE_ZONE"
  cloud        = var.cloud
  region       = var.region
  basic {}

  environment {
    id = confluent_environment.ecommerce.id
  }
}

resource "confluent_flink_compute_pool" "main" {
  display_name     = "standard_compute_pool"
  cloud            = "AWS"
  region           = var.region
  max_cfu          = 10
  environment {
    id = confluent_environment.ecommerce.id
  }
}



resource "confluent_service_account" "app-manager" {
  display_name = "app-manager_${random_id.id.id}"
  description  = "Service account to manage 'inventory' Kafka cluster"

  depends_on = [
    confluent_kafka_cluster.basic
  ]
  
}

data "confluent_organization" "main" {}
resource "confluent_service_account" "statements-runner" {
  display_name = "statements-runner_${random_id.id.id}"
  description  = "Service account for running Flink Statements in 'inventory' Kafka cluster"
}

resource "confluent_role_binding" "app-manager-env-admin" {
  principal   = "User:${confluent_service_account.app-manager.id}"
  role_name   = "EnvironmentAdmin"
  crn_pattern = confluent_environment.ecommerce.resource_name
}

resource "confluent_role_binding" "statements-runner-env-admin" {
  principal   = "User:${confluent_service_account.statements-runner.id}"
  role_name   = "EnvironmentAdmin"
  crn_pattern = confluent_environment.ecommerce.resource_name
}

resource "confluent_role_binding" "app-manager-flink-developer" {
  principal   = "User:${confluent_service_account.app-manager.id}"
  role_name   = "FlinkDeveloper"
  crn_pattern = confluent_environment.ecommerce.resource_name
}
resource "confluent_role_binding" "app-manager-assigner" {
  principal   = "User:${confluent_service_account.app-manager.id}"
  role_name   = "Assigner"
  crn_pattern = "${data.confluent_organization.main.resource_name}/service-account=${confluent_service_account.statements-runner.id}"
}


data "confluent_flink_region" "region" {
  cloud  = "AWS"
  region = confluent_kafka_cluster.basic.region
}

resource "confluent_api_key" "app-manager-kafka-api-key" {
  display_name = "app-manager-kafka-api-key"
  description  = "Kafka API Key that is owned by 'app-manager' service account"
  owner {
    id          = confluent_service_account.app-manager.id
    api_version = confluent_service_account.app-manager.api_version
    kind        = confluent_service_account.app-manager.kind
  }

  managed_resource {
    id          = confluent_kafka_cluster.basic.id
    api_version = confluent_kafka_cluster.basic.api_version
    kind        = confluent_kafka_cluster.basic.kind

    environment {
      id = confluent_environment.ecommerce.id
    }
  }
}

resource "confluent_api_key" "app-manager-schema-registry-api-key" {
  display_name = "env-manager-schema-registry-api-key"
  description  = "Schema Registry API Key that is owned by 'env-manager' service account"
  owner {
    id          = confluent_service_account.app-manager.id
    api_version = confluent_service_account.app-manager.api_version
    kind        = confluent_service_account.app-manager.kind
  }

  managed_resource {
    id          = data.confluent_schema_registry_cluster.sr.id
    api_version = data.confluent_schema_registry_cluster.sr.api_version
    kind        = data.confluent_schema_registry_cluster.sr.kind

    environment {
      id = confluent_environment.ecommerce.id
    }
  }

}

resource "confluent_api_key" "app-manager-flink-api-key" {
  display_name = "app-manager-kafka-api-key"
  description  = "Kafka API Key that is owned by 'app-manager' service account"
  owner {
    id          = confluent_service_account.app-manager.id
    api_version = confluent_service_account.app-manager.api_version
    kind        = confluent_service_account.app-manager.kind
  }

  managed_resource {
    id          = data.confluent_flink_region.region.id
    api_version = data.confluent_flink_region.region.api_version
    kind        = data.confluent_flink_region.region.kind

    environment {
      id = confluent_environment.ecommerce.id
    }
  }
}

resource "confluent_kafka_acl" "app-manager-write-on-topic" {
  kafka_cluster {
    id = confluent_kafka_cluster.basic.id
  }
  resource_type = "TOPIC"
  resource_name = "fa560f9da14"
  pattern_type  = "PREFIXED"
  principal     = "User:${confluent_service_account.app-manager.id}"
  host          = "*"
  operation     = "WRITE"
  permission    = "ALLOW"
  rest_endpoint = confluent_kafka_cluster.basic.rest_endpoint
  credentials {
    key    = confluent_api_key.app-manager-kafka-api-key.id
    secret = confluent_api_key.app-manager-kafka-api-key.secret
  }
}

resource "confluent_kafka_acl" "app-manager-read-on-topic" {
  kafka_cluster {
    id = confluent_kafka_cluster.basic.id
  }
  resource_type = "TOPIC"
  resource_name = "cart_priced"
  pattern_type  = "PREFIXED"
  principal     = "User:${confluent_service_account.app-manager.id}"
  host          = "*"
  operation     = "READ"
  permission    = "ALLOW"
  rest_endpoint = confluent_kafka_cluster.basic.rest_endpoint
  credentials {
    key    = confluent_api_key.app-manager-kafka-api-key.id
    secret = confluent_api_key.app-manager-kafka-api-key.secret
  }
}

resource "confluent_kafka_acl" "app-manager-create-on-topic-dlq" {
  kafka_cluster {
    id = confluent_kafka_cluster.basic.id
  }
  resource_type = "TOPIC"
  resource_name = "dlq-lcc"
  pattern_type  = "PREFIXED"
  principal     = "User:${confluent_service_account.app-manager.id}"
  host          = "*"
  operation     = "CREATE"
  permission    = "ALLOW"
  rest_endpoint = confluent_kafka_cluster.basic.rest_endpoint
  credentials {
    key    = confluent_api_key.app-manager-kafka-api-key.id
    secret = confluent_api_key.app-manager-kafka-api-key.secret
  }
}

resource "confluent_kafka_acl" "app-manager-write-on-topic-dlq" {
  kafka_cluster {
    id = confluent_kafka_cluster.basic.id
  }
  resource_type = "TOPIC"
  resource_name = "dlq-lcc"
  pattern_type  = "PREFIXED"
  principal     = "User:${confluent_service_account.app-manager.id}"
  host          = "*"
  operation     = "WRITE"
  permission    = "ALLOW"
  rest_endpoint = confluent_kafka_cluster.basic.rest_endpoint
  credentials {
    key    = confluent_api_key.app-manager-kafka-api-key.id
    secret = confluent_api_key.app-manager-kafka-api-key.secret
  }
}

resource "confluent_kafka_acl" "app-manager-read-on-topic-connect" {
  kafka_cluster {
    id = confluent_kafka_cluster.basic.id
  }
  resource_type = "GROUP"
  resource_name = "connect-lcc"
  pattern_type  = "PREFIXED"
  principal     = "User:${confluent_service_account.app-manager.id}"
  host          = "*"
  operation     = "READ"
  permission    = "ALLOW"
  rest_endpoint = confluent_kafka_cluster.basic.rest_endpoint
  credentials {
    key    = confluent_api_key.app-manager-kafka-api-key.id
    secret = confluent_api_key.app-manager-kafka-api-key.secret
  }
}


resource "confluent_flink_connection" "openai_embeddings" {
  organization {
    id = data.confluent_organization.main.id
  }
  environment {
    id = confluent_environment.ecommerce.id
  }
  compute_pool {
    id = confluent_flink_compute_pool.main.id
  }
  principal {
    id = confluent_service_account.statements-runner.id
  }
  rest_endpoint   = data.confluent_flink_region.region.rest_endpoint
  credentials {
    key    = confluent_api_key.app-manager-flink-api-key.id
    secret = confluent_api_key.app-manager-flink-api-key.secret
  }

  display_name = "openai-embeddings"
  type = "OPENAI"
  endpoint = "https://api.openai.com/v1/embeddings"
  api_key ="${var.open_api_key}"

}

resource "confluent_flink_connection" "openai_gpt" {
  organization {
    id = data.confluent_organization.main.id
  }
  environment {
    id = confluent_environment.ecommerce.id
  }
  compute_pool {
    id = confluent_flink_compute_pool.main.id
  }
  principal {
    id = confluent_service_account.statements-runner.id
  }
  rest_endpoint   = data.confluent_flink_region.region.rest_endpoint
  credentials {
    key    = confluent_api_key.app-manager-flink-api-key.id
    secret = confluent_api_key.app-manager-flink-api-key.secret
  }

  display_name = "openai-gpt"
  type = "OPENAI"
  endpoint = "https://api.openai.com/v1/chat/completions"
  api_key ="${var.open_api_key}"

}

resource "confluent_flink_connection" "mongo" {
  organization {
    id = data.confluent_organization.main.id
  }
  environment {
    id = confluent_environment.ecommerce.id
  }
  compute_pool {
    id = confluent_flink_compute_pool.main.id
  }
  principal {
    id = confluent_service_account.statements-runner.id
  }
  rest_endpoint   = data.confluent_flink_region.region.rest_endpoint
  credentials {
    key    = confluent_api_key.app-manager-flink-api-key.id
    secret = confluent_api_key.app-manager-flink-api-key.secret
  }

  display_name = "mongo"
  type = "MONGODB"
  endpoint = mongodbatlas_advanced_cluster.commerce.connection_strings.standard_srv
  username = mongodbatlas_database_user.rag_app_user.username
  password = var.db_password

  depends_on = [
    mongodbatlas_advanced_cluster.commerce
  ]
}

resource "confluent_flink_statement" "ddl1" {
  compute_pool {
    id = confluent_flink_compute_pool.main.id
  }
  principal {
    id = confluent_service_account.statements-runner.id
  }
  organization {
    id = data.confluent_organization.main.id
  }
  environment {
    id = confluent_environment.ecommerce.id
  }

  for_each  = toset([
    <<-EOT
CREATE TABLE products (
  `_id` BIGINT NOT NULL,
  `available_for_order` BOOLEAN,
  `uri` string,
  `description` string,
  `description_short` string
)
DISTRIBUTED by (_id)
with(
    'kafka.consumer.isolation-level' = 'read-uncommitted',
    'key.format' = 'json-registry'
);
EOT
    ,
<<-EOT
CREATE TABLE if not exists llm_output (
  `key` STRING NOT NULL,
  vector_search_response_ts TIMESTAMP_LTZ(3),
  prompt STRING,
  `input` STRING,
  `response` STRING,
  `callback_url` STRING
)
DISTRIBUTED by (key)
WITH (
  'kafka.consumer.isolation-level' = 'read-uncommitted',
  'value.format' = 'avro-registry'
)
EOT
    ,
    <<-EOT
create table customer_conversations(
  `key` STRING NOT NULL,
  input STRING,
  callback_url STRING
) distributed by (key) with(
    'kafka.consumer.isolation-level' = 'read-uncommitted'
) ;
EOT
    ,
<<-EOT
CREATE TABLE customer_input_embedding (
  key STRING NOT NULL,
  customer_input_ts TIMESTAMP_LTZ(3),
  input STRING,
  callback_url string,
  input_embedding ARRAY<FLOAT>
)
DISTRIBUTED by(key)
WITH (
  'kafka.consumer.isolation-level' = 'read-uncommitted',
  'value.format' = 'avro-registry'
)
EOT
    ,
    <<-EOT
CREATE TABLE mongodb (
     key bigint,
     description STRING,
     uri STRING,
     available_for_order boolean,
     description_embedding ARRAY<FLOAT>
) WITH (
      'connector' = 'mongodb',
      'mongodb.connection' = 'mongo',
      'mongodb.database' = 'ecommerce',
      'mongodb.collection' = 'products_embedding',
      'mongodb.index' = 'idx_vector_description',
      'mongodb.numcandidates' = '3'
      );
EOT
    ,
<<-EOT
CREATE MODEL openai_gpt
INPUT (message STRING)
OUTPUT (response STRING)
WITH (
  'provider' = 'openai',
  'openai.model_version' = 'gpt-5-chat-latest',
  'openai.connection' = 'openai-gpt',
  'task' = 'text_generation'
);

EOT
  ,
<<-EOT
CREATE TABLE if not exists products_embedding (
  `_id` BIGINT NOT NULL,
  `uri` STRING,
  `available_for_order` BOOLEAN,
  `description` STRING,
  `description_embedding` ARRAY<FLOAT>
)
DISTRIBUTED by(_id)
WITH (
  'kafka.consumer.isolation-level' = 'read-uncommitted',
  'value.format' = 'avro-registry'
)
EOT
  ,
<<-EOT
CREATE TABLE if not exists vector_search_responses (
  `key` string NOT NULL,
  customer_input_embeddings_ts TIMESTAMP_LTZ(3),
  `input` string,
  callback_url string,
  `search_results` ARRAY<ROW<`key` BIGINT, `description` string, `uri` string, available_for_order boolean, `description_embedding` ARRAY<FLOAT>, `score` DOUBLE>>
)                                                                                                                                                              
DISTRIBUTED by (key)
WITH (                                                                                                                                                         
  'kafka.consumer.isolation-level' = 'read-uncommitted',
  'value.format' = 'avro-registry'
)                                                                                                                                                              
EOT
  ,
    <<-EOT
create model `text-embedding-3-large`
INPUT(text string) output(response array<float>)
with(
    'task' = 'embedding',
    'provider' = 'openai',
    'openai.model_version' = 'text-embedding-3-large',
    'openai.connection' = 'openai-embeddings'
)
EOT
  ])
  statement  = each.value
  properties = {
    "sql.current-catalog"  = confluent_environment.ecommerce.display_name
    "sql.current-database" = confluent_kafka_cluster.basic.display_name
  }
  rest_endpoint   = data.confluent_flink_region.region.rest_endpoint
  credentials {
    key    = confluent_api_key.app-manager-flink-api-key.id
    secret = confluent_api_key.app-manager-flink-api-key.secret
  }

  depends_on = [
    confluent_flink_compute_pool.main,
    confluent_flink_connection.openai_embeddings,
    confluent_connector.source,
    confluent_role_binding.app-manager-assigner,
    confluent_role_binding.app-manager-flink-developer
  ]
}

resource "confluent_flink_statement" "alter_ps_category_lang" {
  for_each = toset(["ps_category_lang", "ps_category_product", "ps_product_lang", "ps_product"])

  compute_pool {
    id = confluent_flink_compute_pool.main.id
  }
  principal {
    id = confluent_service_account.statements-runner.id
  }
  organization {
    id = data.confluent_organization.main.id
  }
  environment {
    id = confluent_environment.ecommerce.id
  }

  statement  = <<-EOT
  alter  table `fa560f9da14.prestashop.${each.value}`
    SET ('value.format'='json-registry', 'changelog.mode'='append');
EOT
  properties = {
    "sql.current-catalog"  = confluent_environment.ecommerce.display_name
    "sql.current-database" = confluent_kafka_cluster.basic.display_name
  }
  rest_endpoint   = data.confluent_flink_region.region.rest_endpoint
  credentials {
    key    = confluent_api_key.app-manager-flink-api-key.id
    secret = confluent_api_key.app-manager-flink-api-key.secret
  }

  depends_on = [
    confluent_flink_compute_pool.main,
    confluent_connector.source,
    confluent_role_binding.app-manager-assigner,
    confluent_role_binding.app-manager-flink-developer
  ]
}

resource "confluent_flink_statement" "dml1" {
  compute_pool {
    id = confluent_flink_compute_pool.main.id
  }
  principal {
    id = confluent_service_account.statements-runner.id
  }
  organization {
    id = data.confluent_organization.main.id
  }
  environment {
    id = confluent_environment.ecommerce.id
  }

  for_each  = toset([
<<-EOT
insert into products
select
    p.id_product,
    p.after.available_for_order =1,
    concat(
        c.after.link_rewrite, '/' ,
        cast(p.id_product as string) , '-' ,
        cast (p.after.cache_default_attribute as string), '-' ,
        pl.after.link_rewrite , '.html' ),
    pl.after.description,
    pl.after.description_short
from `fa560f9da14.prestashop.ps_product` p join `fa560f9da14.prestashop.ps_product_lang` pl on p.id_product = pl.id_product
join `fa560f9da14.prestashop.ps_category_product` cp on pl.id_product=cp.id_product and p.after.id_category_default = cp.id_category
join `fa560f9da14.prestashop.ps_category_lang` c on cp.id_category = c.id_category;
EOT
    ,
<<-EOT
insert into products_embedding
SELECT _id, uri, available_for_order, description_short || ' ' || description, response AS description_embedding
FROM `products`,
    LATERAL TABLE(ML_PREDICT('`text-embedding-3-large`',description))
where description IS NOT NULL and description <> '';
EOT
  ,
    <<-EOT
insert into customer_input_embedding
  select
    key,
    $rowtime,
    input,
    callback_url,
    response as input_embedding
  from customer_conversations, lateral table(ML_PREDICT('`text-embedding-3-large`',input))
  where input IS NOT NULL and input <>'';
EOT
,
<<-EOT
insert into vector_search_responses
select key, $rowtime, input, callback_url, search_results
from customer_input_embedding,
    lateral table(
      VECTOR_SEARCH_AGG(
        mongodb,
        DESCRIPTOR (description_embedding),
        input_embedding, 3, MAP ['debug', 'true']
      )
    );
EOT
  ])
  statement  = each.value
  properties = {
    "sql.current-catalog"  = confluent_environment.ecommerce.display_name
    "sql.current-database" = confluent_kafka_cluster.basic.display_name
  }
  rest_endpoint   = data.confluent_flink_region.region.rest_endpoint
  credentials {
    key    = confluent_api_key.app-manager-flink-api-key.id
    secret = confluent_api_key.app-manager-flink-api-key.secret
  }

  depends_on = [
    aws_instance.bastion,
    confluent_connector.source,
    confluent_role_binding.app-manager-assigner,
    confluent_role_binding.app-manager-flink-developer,
    confluent_flink_statement.alter_ps_category_lang,
    confluent_flink_statement.ddl1
  ]
}
resource "confluent_flink_statement" "dml2" {
  compute_pool {
    id = confluent_flink_compute_pool.main.id
  }
  principal {
    id = confluent_service_account.statements-runner.id
  }
  organization {
    id = data.confluent_organization.main.id
  }
  environment {
    id = confluent_environment.ecommerce.id
  }

  statement  = <<-EOT
insert into llm_output
with sr as(
  select $rowtime as vector_search_response_ts, key, input, callback_url, json_array(
  json_object(
    'description' value search_results[1].description,
    'uri' value search_results[1].uri,
'available_for_order' value search_results[1].available_for_order,
    'score' value search_results[1].score
  ),
    json_object(
    'description' value search_results[2].description,
    'uri' value search_results[2].uri,
    'available_for_order' value search_results[2].available_for_order,
    'score' value search_results[2].score
  ),
    json_object(
    'description' value search_results[3].description,
    'uri' value search_results[3].uri,
    'available_for_order' value search_results[3].available_for_order,
    'score' value search_results[3].score
  )
) as search_results
  from `vector_search_responses`
), p as(SELECT
    vector_search_response_ts,
    key,
    input,
    callback_url,
    'As an assistant to an ecommerce shop, answer the question asked by a visitor. You are provided with the context as follows:'
    || cast(search_results as string) ||
    '\nIf the question is about a product, you should find the url in the metadata of each element of the context, then provide this url in your answer.
    Please also prefix all urls with "http://' || '${aws_instance.bastion.public_ip}' || '/" to make them clickable links for the user.
If you find options from the context that are irrelevant, you shall filter it out. If you see a field available_for_order set to false, exclude that option.
Consider your answer will be displayed in a web browser, so format any link as HTML links  (<a>) **NOT MARKDOWN** and carriage return as <br/> HTML tags.
Question: ' || input AS prompt
FROM sr)
select key,vector_search_response_ts, prompt, input, response, callback_url from p, LATERAL TABLE(ML_PREDICT('openai_gpt', prompt));
EOT
  properties = {
    "sql.current-catalog"  = confluent_environment.ecommerce.display_name
    "sql.current-database" = confluent_kafka_cluster.basic.display_name
  }
  rest_endpoint   = data.confluent_flink_region.region.rest_endpoint
  credentials {
    key    = confluent_api_key.app-manager-flink-api-key.id
    secret = confluent_api_key.app-manager-flink-api-key.secret
  }

  depends_on = [
    aws_instance.bastion,
    confluent_connector.source,
    confluent_role_binding.app-manager-assigner,
    confluent_role_binding.app-manager-flink-developer,
    confluent_flink_statement.alter_ps_category_lang,
    confluent_flink_statement.ddl1
  ]
}


resource "confluent_connector" "source" {
  environment {
    id = confluent_environment.ecommerce.id
  }
  kafka_cluster {
    id = confluent_kafka_cluster.basic.id
  }

  config_sensitive = {}

  config_nonsensitive = {
  "name"                      ="CDC_source"
  "connector.class"           ="MySqlCdcSourceV2"
  "database.hostname"         = aws_instance.bastion.public_ip
  "database.include.list"     ="prestashop"
  "database.password"         = var.db_password
  "database.port"             ="3306"
  "topic.prefix"              ="fa560f9da14"
  "database.ssl.mode"         ="preferred"
  "database.user"             = "root"
  "json.output.decimal.format"="NUMERIC"
  "kafka.api.key"             =confluent_api_key.app-manager-kafka-api-key.id
  "kafka.api.secret"          =confluent_api_key.app-manager-kafka-api-key.secret
  "kafka.auth.mode"           ="KAFKA_API_KEY"
  "max.batch.size"            ="1000"
  "output.data.format"        ="AVRO"
  "output.key.format"         ="AVRO"
  "poll.interval.ms"          ="500"
  "errors.deadletterqueue.topic.name" = "db.errors"
  "snapshot.mode"             ="when_needed"
  "table.include.list"        ="prestashop.ps_category_lang, prestashop.ps_cart_product, prestashop.ps_product, prestashop.ps_product_lang,prestashop.ps_category_product"
  "tasks.max"                 ="1"
  "database.history.skip.unparseable.ddl"="true"


  }
  depends_on = [
    confluent_role_binding.app-manager-env-admin
  ]

}

resource "confluent_connector" "mongodb_sink" {
  environment {
    id = confluent_environment.ecommerce.id
  }
  kafka_cluster {
    id = confluent_kafka_cluster.basic.id
  }

  config_nonsensitive = {
    "name"                                = "mongodb-sink-products-embedding"
    "connector.class"                     = "MongoDbAtlasSink"
    "tasks.max"                           = "1"
    "topics"                              = "products_embedding"
    "database"                            = "ecommerce"
    "collection"                          = "products_embedding"
    "input.data.format"                   = "AVRO"
    "input.key.format"                    = "AVRO"
    "doc.id.strategy"                     = "ProvidedInKeyStrategy"
    "errors.tolerance"                    = "all"
    "errors.log.enable"                   = "true"
    "errors.log.include.messages"         = "true"
  }

  config_sensitive = {
    "connection.host"     = replace(mongodbatlas_advanced_cluster.commerce.connection_strings.standard_srv, "mongodb+srv://","")
    "connection.user"     = mongodbatlas_database_user.rag_app_user.username
    "connection.password" = var.db_password
    "kafka.api.key"       =confluent_api_key.app-manager-kafka-api-key.id
    "kafka.api.secret"    =confluent_api_key.app-manager-kafka-api-key.secret

/*
    "value.converter.basic.auth.credentials.source" = "USER_INFO"
    "value.converter.basic.auth.user.info"          = "${confluent_api_key.app-manager-schema-registry-api-key.id}:${confluent_api_key.app-manager-schema-registry-api-key.secret}"
*/
  }

  depends_on = [
    confluent_flink_statement.ddl1,
    null_resource.collection_creator
  ]
}


resource "confluent_connector" "http_sink" {
  environment {
    id = confluent_environment.ecommerce.id
  }
  kafka_cluster {
    id = confluent_kafka_cluster.basic.id
  }

  config_nonsensitive = {
    "name"                                = "http-sink-llm-output"
    "connector.class"                     = "HttpSink"
    "topics"              = "llm_output"
    "http.api.url"        = "http://${aws_instance.bastion.public_ip}/chat2-api$${callback_url}"
    "input.key.format"    = "BYTES"
    "tasks.max"           = "1"
    "request.body.format" = "json"
    "headers"             = "Content-type: application/json"
    "input.data.format"                   = "AVRO"
    "errors.tolerance"                    = "all"
    "errors.log.enable"                   = "true"
    "errors.log.include.messages"         = "true"
  }

  config_sensitive = {
    "kafka.api.key"       =confluent_api_key.app-manager-kafka-api-key.id
    "kafka.api.secret"    =confluent_api_key.app-manager-kafka-api-key.secret

/*
    "value.converter.basic.auth.credentials.source" = "USER_INFO"
    "value.converter.basic.auth.user.info"          = "${confluent_api_key.app-manager-schema-registry-api-key.id}:${confluent_api_key.app-manager-schema-registry-api-key.secret}"
*/
  }

  depends_on = [
    confluent_flink_statement.ddl1,
    null_resource.collection_creator
  ]
}

