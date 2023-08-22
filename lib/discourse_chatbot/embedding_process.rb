# frozen_string_literal: true
require "openai"

module ::DiscourseChatbot

  EMBEDDING_MODEL = "text-embedding-ada-002".freeze
  CHAR_LIMIT = 32000

  class EmbeddingProcess

    def initialize
      if SiteSetting.chatbot_azure_open_ai_model_url.include?("azure")
        ::OpenAI.configure do |config|
          config.access_token = SiteSetting.chatbot_azure_open_ai_token
          config.uri_base = SiteSetting.chatbot_azure_open_ai_model_url
          config.api_type = :azure
          config.api_version = "2023-05-15"
        end
        @client = ::OpenAI::Client.new
      else
        @client = ::OpenAI::Client.new(access_token: SiteSetting.chatbot_open_ai_token)
      end
    end

    def upsert_embedding(post_id)
      benchmark_user = User.where(trust_level: 1, active: true, admin: false, suspended_at: nil).last
      if benchmark_user.nil?
        raise StandardError, "No benchmark user exists for Post embedding suitability check, please add a basic user"
      end
      benchmark_user_guardian = Guardian.new(benchmark_user)

      post = ::Post.find_by(id: post_id)

      return if post.nil?

      if benchmark_user_guardian.can_see?(post)
        response = @client.embeddings(
          parameters: {
            model: EMBEDDING_MODEL,
            input: post.raw[0..CHAR_LIMIT]
          }
        )

        embedding_vector = response.dig("data", 0, "embedding")

        ::DiscourseChatbot::Embedding.upsert({ post_id: post_id, embedding: embedding_vector }, on_duplicate: :update, unique_by: :post_id)
      end
    end

    def semantic_search(query)
      response = @client.embeddings(
        parameters: {
          model: EMBEDDING_MODEL,
          input: query[0..CHAR_LIMIT]
        }
       )

       query_vector = response.dig("data", 0, "embedding")

       begin
         search_result_post_ids =
           DB.query(<<~SQL, query_embedding: query_vector, limit: 8).map(
              SELECT
                post_id
              FROM
                chatbot_embeddings
              ORDER BY
               embedding::real[] <-> array[:query_embedding]
              LIMIT :limit
            SQL
             &:post_id
           )
        rescue PG::Error => e
          Rails.logger.error(
            "Error #{e} querying embeddings for search #{query}",
          )
         raise MissingEmbeddingError
       end
       search_result_post_ids
    end
  end
end
