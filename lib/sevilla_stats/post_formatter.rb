# frozen_string_literal: true

module SevillaStats
  class PostFormatter
    SEVILLA_CREST   = "https://crests.football-data.org/559.png"
    COMPETITION_EMBLEMS = {
      "2014" => "https://crests.football-data.org/PD.png",
      "2015" => "https://crests.football-data.org/CDR.png",
      "2018" => "https://crests.football-data.org/UEL.png",
      "2001" => "https://crests.football-data.org/UCL.png"
    }.freeze

    COMPETITION_LABELS = {
      "2014" => "La Liga",
      "2015" => "Copa del Rey",
      "2018" => "UEFA Europa League",
      "2001" => "UEFA Champions League"
    }.freeze

    POSITION_ORDER = %w[Goalkeeper Defender Midfielder Forward Attacker].freeze

    # -------------------------------------------------------------------------
    # Build the initial pinned topic body (created on first run)
    # -------------------------------------------------------------------------
    def self.initial_topic_body(season)
      year_start = season.to_i
      year_end   = year_start + 1

      <<~MD
        # :bar_chart: Sevilla FC — #{year_start}/#{year_end} Season Statistics

        ![Sevilla FC](#{SEVILLA_CREST})

        Welcome to the **official season stats thread** for Sevilla FC's #{year_start}/#{year_end} campaign.

        This thread is automatically updated after every match across all competitions.
        Each reply below contains a full stats update for that matchday.

        ---

        ## :clipboard: How to Read This Thread

        - **This post** is the index — scroll down for individual matchday updates
        - Stats cover **La Liga**, **Copa del Rey**, and **European competition**
        - Player stats are aggregated across all competitions in the summary

        ---

        ## :trophy: Competitions This Season

        | Competition | Emblem |
        |-------------|--------|
        | La Liga | ![La Liga](#{COMPETITION_EMBLEMS["2014"]}) |
        | Copa del Rey | ![Copa del Rey](#{COMPETITION_EMBLEMS["2015"]}) |
        | UEFA Europa League | ![UEL](#{COMPETITION_EMBLEMS["2018"]}) |

        ---

        *First stats update will appear as a reply below after the next completed match.*

        *Last generated: #{Time.now.strftime("%d %B %Y")}*
      MD
    end

    # -------------------------------------------------------------------------
    # Build a matchday update reply post
    # match_info: hash with match details
    # new_stats:  array of SevillaPlayerStat records (current season totals)
    # standings:  array of standing rows (optional)
    # -------------------------------------------------------------------------
    def self.matchday_update(match_info:, season:, standings: [])
      competition_id   = match_info[:competition_id].to_s
      competition_name = COMPETITION_LABELS[competition_id] || match_info[:competition_name]
      comp_emblem      = COMPETITION_EMBLEMS[competition_id]
      matchday_label   = match_info[:matchday] ? "Matchday #{match_info[:matchday]}" : "Match"

      year_start = season.to_i
      year_end   = year_start + 1

      # Determine result text
      home = match_info[:home_team]
      away = match_info[:away_team]
      hs   = match_info[:home_score]
      as_  = match_info[:away_score]
      result_emoji = sevilla_result_emoji(home, away, hs, as_)

      lines = []
      lines << "---"
      lines << ""

      # Header
      if comp_emblem
        lines << "## #{result_emoji} #{matchday_label} Update | ![#{competition_name}](#{comp_emblem}) #{competition_name}"
      else
        lines << "## #{result_emoji} #{matchday_label} Update | #{competition_name}"
      end

      lines << ""
      lines << "> **#{home} #{hs}–#{as_} #{away}** | #{match_info[:match_date]&.strftime("%d %B %Y")}"
      lines << ""

      # Season totals header
      lines << "### :bar_chart: Season Totals — #{year_start}/#{year_end} (All Competitions)"
      lines << ""

      # Goals & Assists table
      lines << build_goals_assists_table(season)
      lines << ""

      # Appearances & Minutes table
      lines << build_appearances_table(season)
      lines << ""

      # Discipline table
      lines << build_discipline_table(season)
      lines << ""

      # Per-competition breakdown
      lines << "### :clipboard: By Competition"
      lines << ""

      competition_ids_with_data(season).each do |comp_id|
        comp_label   = COMPETITION_LABELS[comp_id] || comp_id
        comp_emblem2 = COMPETITION_EMBLEMS[comp_id]
        header = comp_emblem2 ? "#### ![#{comp_label}](#{comp_emblem2}) #{comp_label}" : "#### #{comp_label}"
        lines << header
        lines << ""
        lines << build_competition_table(season, comp_id)
        lines << ""
      end

      # League table (if La Liga data available)
      if competition_id == "2014" && standings.any?
        lines << "### :trophy: La Liga Standings (Top 10)"
        lines << ""
        lines << build_standings_table(standings)
        lines << ""
      end

      lines << "*Stats updated: #{Time.now.strftime("%d %B %Y %H:%M")} UTC*"
      lines << ""

      lines.join("\n")
    end

    # =========================================================================
    private
    # =========================================================================

    def self.sevilla_result_emoji(home_team, away_team, home_score, away_score)
      sevilla_home = home_team.to_s.downcase.include?("sevilla")
      sevilla_score = sevilla_home ? home_score.to_i : away_score.to_i
      opp_score     = sevilla_home ? away_score.to_i : home_score.to_i

      if sevilla_score > opp_score
        ":white_check_mark:"
      elsif sevilla_score == opp_score
        ":handshake:"
      else
        ":x:"
      end
    end

    def self.build_goals_assists_table(season)
      rows = SevillaPlayerStat
               .season_totals(season)
               .having("SUM(goals) > 0 OR SUM(assists) > 0")
               .limit(15)

      return "_No goal/assist data yet._" if rows.empty?

      lines = []
      lines << "**:goal_net: Goals & Assists**"
      lines << ""
      lines << "| # | Player | Position | Goals | Assists | Matches |"
      lines << "|---|--------|----------|------:|--------:|--------:|"

      rows.each_with_index do |r, i|
        lines << "| #{i + 1} | #{r.player_name} | #{r.position || "—"} | **#{r.total_goals}** | #{r.total_assists} | #{r.total_appearances} |"
      end

      lines.join("\n")
    end

    def self.build_appearances_table(season)
      rows = SevillaPlayerStat
               .season_totals(season)
               .having("SUM(appearances) > 0")
               .reorder(Arel.sql("SUM(appearances) DESC, SUM(minutes_played) DESC"))
               .limit(20)

      return "_No appearances data yet._" if rows.empty?

      lines = []
      lines << "**:shirt: Appearances & Minutes**"
      lines << ""
      lines << "| Player | Position | Apps | Minutes |"
      lines << "|--------|----------|-----:|--------:|"

      rows.each do |r|
        lines << "| #{r.player_name} | #{r.position || "—"} | #{r.total_appearances} | #{r.total_minutes} |"
      end

      lines.join("\n")
    end

    def self.build_discipline_table(season)
      rows = SevillaPlayerStat
               .season_totals(season)
               .having("SUM(yellow_cards) > 0 OR SUM(red_cards) > 0")
               .reorder(Arel.sql("SUM(yellow_cards + red_cards) DESC"))

      return "_No discipline data yet._" if rows.empty?

      lines = []
      lines << "**:yellow_square: Discipline**"
      lines << ""
      lines << "| Player | :yellow_square: Yellow | :red_square: Red |"
      lines << "|--------|----------------------:|----------------:|"

      rows.each do |r|
        lines << "| #{r.player_name} | #{r.total_yellow_cards} | #{r.total_red_cards} |"
      end

      lines.join("\n")
    end

    def self.build_competition_table(season, competition_id)
      rows = SevillaPlayerStat
               .for_season(season)
               .for_competition(competition_id)
               .where("goals > 0 OR assists > 0 OR appearances > 0")
               .order(goals: :desc, assists: :desc, appearances: :desc)
               .limit(15)

      return "_No data for this competition yet._" if rows.empty?

      lines = []
      lines << "| Player | Apps | Mins | Goals | Assists | :yellow_square: | :red_square: |"
      lines << "|--------|-----:|-----:|------:|--------:|:--------------:|:------------:|"

      rows.each do |r|
        lines << "| #{r.player_name} | #{r.appearances} | #{r.minutes_played} | #{r.goals} | #{r.assists} | #{r.yellow_cards} | #{r.red_cards} |"
      end

      lines.join("\n")
    end

    def self.build_standings_table(standings)
      lines = []
      lines << "| Pos | Club | P | W | D | L | GF | GA | GD | Pts |"
      lines << "|----:|-----|--:|--:|--:|--:|---:|---:|---:|----:|"

      standings.first(10).each do |row|
        team_name = row.dig("team", "name") || "Unknown"
        bold_open  = team_name.downcase.include?("sevilla") ? "**" : ""
        bold_close = team_name.downcase.include?("sevilla") ? "**" : ""

        lines << "| #{bold_open}#{row["position"]}#{bold_close} | #{bold_open}#{team_name}#{bold_close} | #{row["playedGames"]} | #{row["won"]} | #{row["draw"]} | #{row["lost"]} | #{row["goalsFor"]} | #{row["goalsAgainst"]} | #{row["goalDifference"]} | #{bold_open}#{row["points"]}#{bold_close} |"
      end

      lines.join("\n")
    end

    def self.competition_ids_with_data(season)
      SevillaPlayerStat
        .for_season(season)
        .distinct
        .pluck(:competition_id)
        .sort
    end
  end
end
