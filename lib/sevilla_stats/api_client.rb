# frozen_string_literal: true

module SevillaStats
  class ApiClient
    BASE_URL    = "https://api.football-data.org/v4"
    SEVILLA_ID  = 559  # Sevilla FC team ID on football-data.org

    # Competition name map
    COMPETITION_NAMES = {
      "2014" => "La Liga",
      "2079" => "Copa del Rey",
      "2146" => "UEFA Europa League",
      "2001" => "UEFA Champions League",
      "2154" => "UEFA Conference League"
    }.freeze

    def initialize(api_key)
      @api_key = api_key
    end

    # -------------------------------------------------------------------------
    # Fetch all finished Sevilla matches for a given season
    # Returns array of match hashes
    # -------------------------------------------------------------------------
    def sevilla_finished_matches(season)
      team_id = SiteSetting.sevilla_stats_team_id
      response = get("/teams/#{team_id}/matches", { season: season, status: "FINISHED" })
      return [] unless response && response["matches"]

      response["matches"].select do |m|
        competition_ids.include?(m.dig("competition", "id").to_s)
      end
    end

    # -------------------------------------------------------------------------
    # Fetch top scorers for a competition/season
    # Returns array of scorer hashes: { player, team, goals, assists, playedMatches }
    # -------------------------------------------------------------------------
    def top_scorers(competition_id, season)
      response = get("/competitions/#{competition_id}/scorers",
                     { season: season, limit: 50 })
      return [] unless response && response["scorers"]

      # Filter to only Sevilla players
      team_id = SiteSetting.sevilla_stats_team_id
      response["scorers"].select do |s|
        s.dig("team", "id") == team_id
      end
    end

    # -------------------------------------------------------------------------
    # Fetch standings for a competition/season
    # Returns the full standings table array
    # -------------------------------------------------------------------------
    def standings(competition_id, season)
      response = get("/competitions/#{competition_id}/standings",
                     { season: season })
      return [] unless response && response["standings"]

      # Return the TOTAL standings table (as opposed to HOME or AWAY)
      total_table = response["standings"].find { |s| s["type"] == "TOTAL" }
      total_table ? total_table["table"] : []
    end

    # -------------------------------------------------------------------------
    # Fetch squad for Sevilla (for appearances/minutes — built from match data)
    # -------------------------------------------------------------------------
    def sevilla_squad
      team_id = SiteSetting.sevilla_stats_team_id
      response = get("/teams/#{team_id}")
      return [] unless response && response["squad"]

      response["squad"]
    end

    # -------------------------------------------------------------------------
    # Fetch a single match with lineup details (for cards and minutes)
    # -------------------------------------------------------------------------
    def match_detail(match_id)
      get("/matches/#{match_id}")
    end

    # -------------------------------------------------------------------------
    # Competition IDs configured in settings
    # -------------------------------------------------------------------------
    def competition_ids
      SiteSetting.sevilla_stats_competition_ids.split(",").map(&:strip)
    end

    def competition_name(competition_id)
      COMPETITION_NAMES[competition_id.to_s] || "Unknown Competition"
    end

    # -------------------------------------------------------------------------
    # Fetch the emblem URL for a competition, returns nil if unavailable/404
    # Results are cached in-memory for the lifetime of the client instance
    # -------------------------------------------------------------------------
    def competition_emblem(competition_id)
      @emblem_cache ||= {}
      return @emblem_cache[competition_id.to_s] if @emblem_cache.key?(competition_id.to_s)

      response = get("/competitions/#{competition_id}")
      emblem_url = response&.dig("emblem")

      # Verify the emblem URL actually resolves (guard against 404s)
      verified_url = emblem_url && emblem_reachable?(emblem_url) ? emblem_url : nil

      @emblem_cache[competition_id.to_s] = verified_url
      verified_url
    end

    # -------------------------------------------------------------------------
    # Fetch emblem URLs for all configured competitions
    # Returns a hash of { competition_id => url_or_nil }
    # -------------------------------------------------------------------------
    def competition_emblems
      competition_ids.each_with_object({}) do |comp_id, hash|
        hash[comp_id] = competition_emblem(comp_id)
      end
    end

    private

    def get(path, params = {})
      uri = URI("#{BASE_URL}#{path}")
      uri.query = URI.encode_www_form(params) unless params.empty?

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 15
      http.open_timeout = 10

      request = Net::HTTP::Get.new(uri)
      request["X-Auth-Token"] = @api_key
      request["Accept"]       = "application/json"

      response = http.request(request)

      case response.code.to_i
      when 200
        JSON.parse(response.body)
      when 429
        Rails.logger.warn("[SevillaStats] API rate limited — will retry next cycle")
        nil
      when 403
        Rails.logger.error("[SevillaStats] API key invalid or unauthorized")
        nil
      else
        Rails.logger.error("[SevillaStats] API error #{response.code}: #{response.body.truncate(200)}")
        nil
      end
    rescue Net::ReadTimeout, Net::OpenTimeout => e
      Rails.logger.error("[SevillaStats] API timeout: #{e.message}")
      nil
    rescue JSON::ParserError => e
      Rails.logger.error("[SevillaStats] JSON parse error: #{e.message}")
      nil
    end

    # HEAD request to verify an emblem image URL exists (not a 404)
    def emblem_reachable?(url)
      uri  = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl     = (uri.scheme == "https")
      http.read_timeout = 5
      http.open_timeout = 5

      request  = Net::HTTP::Head.new(uri)
      response = http.request(request)
      response.code.to_i == 200
    rescue StandardError => e
      Rails.logger.warn("[SevillaStats] Could not verify emblem URL #{url}: #{e.message}")
      false
    end
  end
end
