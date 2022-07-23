require "sidekiq"
require "mysql2-cs-bind"

require_relative "../config/sentry_methods"
require_relative "../config/redis_methods"
require_relative "../isucon_helper"

class TenantRankingWorker
  include Sidekiq::Worker
  include SentryMethods
  include IsuconHelper
  include RedisMethods

  sidekiq_options queue: "default"

  def perform(tenant_id, competition_id)
    with_sentry do
      connect_to_tenant_db(tenant_id) do |tenant_db|
        # player_scoreを読んでいるときに更新が走ると不整合が起こるのでロックを取得する
        flock_by_tenant_id(tenant_id) do
          ranks = []
          scored_player_set = Set.new
          tenant_db.execute('SELECT * FROM player_score WHERE tenant_id = ? AND competition_id = ? ORDER BY row_num DESC', [tenant_id, competition_id]) do |row|
            ps = PlayerScoreRow.new(row)
            # player_scoreが同一player_id内ではrow_numの降順でソートされているので
            # 現れたのが2回目以降のplayer_idはより大きいrow_numでスコアが出ているとみなせる
            if scored_player_set.member?(ps.player_id)
              next
            end
            scored_player_set.add(ps.player_id)
            player = retrieve_player(tenant_db, ps.player_id)
            ranks.push(CompetitionRank.new(
              score: ps.score,
              player_id: player.id,
              player_display_name: player.display_name,
              row_num: ps.row_num,
            ))
          end

          ranks.sort_by! { |a| [-a.score, a.row_num] }

          save_value_to_redis(ranking_key(tenant_id:tenant_id, competition_id: competition_id), ranks)
        end
      end
    end
  end
end
