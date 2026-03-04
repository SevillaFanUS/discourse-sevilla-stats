# frozen_string_literal: true

# name: discourse-sevilla-stats
# about: Automatically tracks and posts Sevilla FC season statistics after every match
# version: 1.0.0
# authors: MonchisMen
# url: https://monchismen.com

enabled_site_setting :sevilla_stats_enabled

# ============================================================================
# Load dependencies
# ============================================================================

require "net/http"
require "uri"
require "json"

# ============================================================================
# Register library files
# ============================================================================

%w[
  api_client
  stats_aggregator
  post_formatter
].each do |lib|
  load File.expand_path("../lib/sevilla_stats/#{lib}.rb", __FILE__)
end

# ============================================================================
# Register DB migrations
# ============================================================================

register_asset "stylesheets/sevilla_stats.scss" if Rails.root.join("plugins/discourse-sevilla-stats/assets/stylesheets/sevilla_stats.scss").exist?

after_initialize do
  # -------------------------------------------------------------------------
  # Load models
  # -------------------------------------------------------------------------
  require_relative "app/models/sevilla_player_stat"
  require_relative "app/models/sevilla_stats_job_log"

  # -------------------------------------------------------------------------
  # Load scheduled job
  # -------------------------------------------------------------------------
  require_relative "app/jobs/scheduled/update_sevilla_stats"

  # -------------------------------------------------------------------------
  # Admin route to trigger a manual stats refresh
  # (accessible via /admin/plugins — useful for testing)
  # -------------------------------------------------------------------------
  Discourse::Application.routes.append do
    namespace :admin, constraints: StaffConstraint.new do
      post "plugins/sevilla-stats/refresh" => "plugins/sevilla_stats/refresh#create"
    end
  end

  # Admin controller for manual refresh
  module ::Admin
    module Plugins
      module SevnillaStats
      end
    end
  end

  class Admin::Plugins::SevillaStats::RefreshController < Admin::AdminController
    requires_plugin "discourse-sevilla-stats"

    def create
      Jobs.enqueue(:update_sevilla_stats)
      render json: { success: true, message: "Stats refresh job enqueued." }
    end
  end

  # -------------------------------------------------------------------------
  # Log startup
  # -------------------------------------------------------------------------
  Rails.logger.info("[SevillaStats] Plugin loaded — scheduler active") if SiteSetting.sevilla_stats_enabled
end
