# frozen_string_literal: true

module Jobs
  class UpdateSevillaStats < ::Jobs::Scheduled
    # Run every 3 hours (configurable via settings)
    every 3.hours

    def execute(_args)
      return unless SiteSetting.sevilla_stats_enabled
      return if SiteSetting.sevilla_stats_api_key.blank?

      Rails.logger.info("[SevillaStats] Starting stats update job")

      season     = SiteSetting.sevilla_stats_season
      api_client = SevillaStats::ApiClient.new(SiteSetting.sevilla_stats_api_key)
      aggregator = SevillaStats::StatsAggregator.new(api_client, season)

      # Fetch and verify emblem URLs once per job run (results are cached on api_client)
      emblems = api_client.competition_emblems
      Rails.logger.info("[SevillaStats] Resolved emblems: #{emblems.map { |k, v| "#{k}=#{v || 'nil'}" }.join(", ")}")

      # Step 1: Ensure the season stats topic exists
      topic = ensure_season_stats_topic!(season, emblems)
      return unless topic

      # Step 2: Refresh all stats and find new unprocessed matches
      new_matches = aggregator.refresh_all_stats!

      if new_matches.empty?
        Rails.logger.info("[SevillaStats] No new matches found — nothing to post")
        return
      end

      Rails.logger.info("[SevillaStats] Found #{new_matches.size} new match(es) to process")

      # Step 3: For each new match, enrich stats from lineup data, then post update
      new_matches.each do |match|
        process_match!(match, aggregator, topic, season, api_client, emblems)
      end
    rescue => e
      Rails.logger.error("[SevillaStats] Job failed: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
    end

    private

    # -------------------------------------------------------------------------
    # Ensure the season stats topic exists; create it on first run if missing
    # -------------------------------------------------------------------------
    def ensure_season_stats_topic!(season, emblems = {})
      stored_topic_id = SiteSetting.sevilla_stats_topic_id.to_i

      if stored_topic_id > 0
        topic = Topic.find_by(id: stored_topic_id)
        return topic if topic && !topic.trashed?
        Rails.logger.warn("[SevillaStats] Stored topic ID #{stored_topic_id} not found — recreating")
      end

      Rails.logger.info("[SevillaStats] Creating Season Stats topic for season #{season}")
      create_season_stats_topic!(season, emblems)
    rescue => e
      Rails.logger.error("[SevillaStats] Failed to ensure season stats topic: #{e.message}")
      nil
    end

    def create_season_stats_topic!(season, emblems = {})
      year_start  = season.to_i
      year_end    = year_start + 1
      category_id = SiteSetting.sevilla_stats_category_id

      category = Category.find_by(id: category_id)
      unless category
        Rails.logger.error("[SevillaStats] Category #{category_id} not found")
        return nil
      end

      post_author = User.find_by(id: -1) || User.admins.first
      unless post_author
        Rails.logger.error("[SevillaStats] No suitable author user found")
        return nil
      end

      title = "Sevilla FC #{year_start}/#{year_end} Season Stats"
      body  = SevillaStats::PostFormatter.initial_topic_body(season, emblems)

      post_creator = PostCreator.new(
        post_author,
        title:              title,
        raw:                body,
        category:           category_id,
        skip_validations:   false,
        skip_jobs:          false
      )

      post = post_creator.create

      unless post&.persisted?
        errors = post_creator.errors.full_messages.join(", ")
        Rails.logger.error("[SevillaStats] Failed to create topic: #{errors}")
        return nil
      end

      topic = post.topic

      # Pin the topic globally
      topic.update_pinned(true, true)

      # Apply tag if configured
      tag_name = SiteSetting.sevilla_stats_topic_tag.strip
      if tag_name.present?
        tag = Tag.find_or_create_by(name: tag_name)
        topic.tags << tag unless topic.tags.include?(tag)
      end

      # Persist the topic ID in settings so we reuse it
      SiteSetting.sevilla_stats_topic_id = topic.id

      Rails.logger.info("[SevillaStats] Season Stats topic created: ##{topic.id} — '#{title}'")
      topic
    end

    # -------------------------------------------------------------------------
    # Process a single finished match: enrich stats, then post reply
    # -------------------------------------------------------------------------
    def process_match!(match, aggregator, topic, season, api_client, emblems = {})
      match_id       = match["id"]
      competition_id = match.dig("competition", "id").to_s
      competition_name = match.dig("competition", "name")
      matchday       = match["matchday"]
      home_team      = match.dig("homeTeam", "name") || match.dig("homeTeam", "shortName") || "Home"
      away_team      = match.dig("awayTeam", "name") || match.dig("awayTeam", "shortName") || "Away"
      home_score     = match.dig("score", "fullTime", "home") || match.dig("score", "fullTime", "homeTeam")
      away_score     = match.dig("score", "fullTime", "away") || match.dig("score", "fullTime", "awayTeam")
      match_date     = parse_match_date(match["utcDate"])

      Rails.logger.info("[SevillaStats] Processing match #{match_id}: #{home_team} #{home_score}–#{away_score} #{away_team}")

      # Enrich player stats from match lineup (adds minutes & cards)
      aggregator.enrich_from_match!(match_id, competition_id)

      # Fetch current standings if this is a La Liga match
      standings = []
      if competition_id == "2014"
        standings = api_client.standings(competition_id, season) rescue []
      end

      # Build the post body
      match_info = {
        competition_id:   competition_id,
        competition_name: competition_name,
        matchday:         matchday,
        home_team:        home_team,
        away_team:        away_team,
        home_score:       home_score,
        away_score:       away_score,
        match_date:       match_date
      }

      post_body = SevillaStats::PostFormatter.matchday_update(
        match_info: match_info,
        season:     season,
        standings:  standings,
        emblems:    emblems
      )

      # Post the reply
      post_author = User.find_by(id: -1) || User.admins.first
      post        = create_reply!(topic, post_author, post_body)

      # Log the processed match
      SevillaStatsJobLog.record_processed!(
        match_id:          match_id,
        competition_id:    competition_id,
        competition_name:  competition_name,
        matchday:          matchday,
        home_team:         home_team,
        away_team:         away_team,
        home_score:        home_score,
        away_score:        away_score,
        match_date:        match_date || Time.now,
        discourse_post_id: post&.id
      )

      Rails.logger.info("[SevillaStats] Posted reply for match #{match_id} (post ##{post&.id})")
    rescue => e
      Rails.logger.error("[SevillaStats] Error processing match #{match["id"]}: #{e.message}\n#{e.backtrace.first(3).join("\n")}")
    end

    def create_reply!(topic, author, raw)
      creator = PostCreator.new(
        author,
        topic_id:         topic.id,
        raw:              raw,
        skip_validations: false,
        skip_jobs:        false
      )

      post = creator.create

      unless post&.persisted?
        errors = creator.errors.full_messages.join(", ")
        Rails.logger.error("[SevillaStats] Failed to create reply: #{errors}")
        return nil
      end

      post
    end

    def parse_match_date(utc_string)
      return nil if utc_string.blank?
      Time.parse(utc_string).utc
    rescue ArgumentError
      nil
    end
  end
end
