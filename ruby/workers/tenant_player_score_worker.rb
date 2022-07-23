require "sidekiq"
require "mysql2-cs-bind"

require_relative "../config/sentry_methods"
require_relative "../isucon_helper"

class TenantPlayerScoreWorker
  include Sidekiq::Worker
  include SentryMethods
  include IsuconHelper
  include RedisMethods

  sidekiq_options queue: "default"

  def perform(tenant_id, player_id)
    # FIXME: connect_to_tenant_dbでエラーになるので無理やり設定する
    @trace_file_path = ""

    with_sentry do
      connect_to_tenant_db(tenant_id) do |tenant_db|
        competitions = tenant_db.execute('SELECT * FROM competition WHERE tenant_id = ? ORDER BY created_at ASC', [tenant_id]).map { |row| CompetitionRow.new(row) }

        # player_scoreを読んでいるときに更新が走ると不整合が起こるのでロックを取得する
        flock_by_tenant_id(tenant_id) do
          player_score_rows = competitions.filter_map do |c|
            # 最後にCSVに登場したスコアを採用する = row_numが一番大きいもの
            row = tenant_db.get_first_row('SELECT * FROM player_score WHERE tenant_id = ? AND competition_id = ? AND player_id = ? ORDER BY row_num DESC LIMIT 1', [tenant_id, c.id, player_id])
            if row
              PlayerScoreRow.new(row)
            else
              # 行がない = スコアが記録されてない
              nil
            end
          end

          scores = player_score_rows.map do |ps|
            comp = retrieve_competition(tenant_db, ps.competition_id)
            {
              competition_title: comp.title,
              score: ps.score,
            }
          end

          save_player_score_to_redis(tenant_id: tenant_id, player_id: player_id, value: scores)
        end
      end
    end
  end
end
