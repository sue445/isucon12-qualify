# frozen_string_literal: true

require 'csv'
require 'jwt'
require 'mysql2'
require 'mysql2-cs-bind'
require 'open3'
require 'openssl'
require 'set'
require 'sinatra/base'
require 'sinatra/cookies'
require 'sinatra/json'
require 'sqlite3'

require_relative 'sqltrace'
require_relative './isucon_helper'

# TODO: Sinatra app内で include SentryMethods する
require_relative "./config/sentry_methods"

# 必要に応じて使う
# require "mysql2-nested_hash_bind"
# require_relative "./config/hash_group_by_prefix"
# require_relative "./config/mysql_methods"
require_relative "./config/oj_encoder"
require_relative "./config/oj_to_json_patch"
# require_relative "./config/redis_methods"
# require_relative "./config/sidekiq"
# require_relative "./config/sidekiq_methods"

# TODO: 終了直前にコメントアウトする
require_relative "./config/enable_monitoring"

# NOTE: enable_monitoringでddtraceとdatadog_thread_tracerをrequireしてるのでenable_monitoringをrequireした後でrequireする必要がある
require_relative "./config/thread_helper"

module Isuports
  class App < Sinatra::Base
    include SentryMethods
    # using Mysql2::NestedHashBind::QueryExtension

    set :json_encoder, OjEncoder.instance

    disable :logging
    set :show_exceptions, :after_handler
    configure :development do
      require 'sinatra/reloader'
      register Sinatra::Reloader
    end
    helpers Sinatra::Cookies

    before do
      cache_control :private
    end

    TENANT_DB_SCHEMA_FILE_PATH = '../sql/tenant/10_schema.sql'
    INITIALIZE_SCRIPT = '../sql/init.sh'
    # COOKIE_NAME = 'isuports_session'

    # ROLE_ADMIN = 'admin'
    # ROLE_ORGANIZER = 'organizer'
    # ROLE_PLAYER = 'player'
    # ROLE_NONE = 'none'

    # 正しいテナント名の正規表現
    TENANT_NAME_REGEXP = /^[a-z][a-z0-9-]{0,61}[a-z0-9]$/

    # アクセスしてきた人の情報
    Viewer = Struct.new(:role, :player_id, :tenant_name, :tenant_id, keyword_init: true)

    TenantRow = Struct.new(:id, :name, :display_name, :created_at, :updated_at, keyword_init: true)
    PlayerRow = Struct.new(:tenant_id, :id, :display_name, :is_disqualified, :created_at, :updated_at, keyword_init: true)
    CompetitionRow = Struct.new(:tenant_id, :id, :title, :finished_at, :created_at, :updated_at, keyword_init: true)
    PlayerScoreRow = Struct.new(:tenant_id, :id, :player_id, :competition_id, :score, :row_num, :created_at, :updated_at, keyword_init: true)

    def initialize(*, **)
      super
      @trace_file_path = ENV.fetch('ISUCON_SQLITE_TRACE_FILE', '')
      unless @trace_file_path.empty?
        SQLite3TraceLog.open(@trace_file_path)
      end
    end

    helpers IsuconHelper

    # エラー処理
    error HttpError do
      e = env['sinatra.error']
      
      content_type :json
      status e.code
      JSON.dump(status: false)
    end

    # SaaS管理者向けAPI

    # テナントを追加する
    post '/api/admin/tenants/add' do
      v = parse_viewer
      if v.tenant_name != 'admin'
        # admin: SaaS管理者用の特別なテナント名
        raise HttpError.new(404, "#{v.tenant_name} has not this API")
      end
      if v.role != ROLE_ADMIN
        raise HttpError.new(403, 'admin role required')
      end

      display_name = params[:display_name]
      name = params[:name]
      validate_tenant_name!(name)

      now = Time.now.to_i
      begin
        admin_db.xquery('INSERT INTO tenant (name, display_name, created_at, updated_at) VALUES (?, ?, ?, ?)', name, display_name, now, now)
      rescue Mysql2::Error => e
        if e.error_number == 1062 # duplicate entry
          raise HttpError.new(400, 'duplicate tenant')
        end
        raise e
      end
      id = admin_db.last_id
      # NOTE: 先にadmin_dbに書き込まれることでこのAPIの処理中に
      #       /api/admin/tenants/billingにアクセスされるとエラーになりそう
      #       ロックなどで対処したほうが良さそう
      create_tenant_db(id)
      json(
        status: true,
        data: {
          tenant: {
            id: id.to_s,
            name: name,
            display_name: display_name,
            billing: 0,
          },
        },
      )
    end

    # テナントごとの課金レポートを最大10件、テナントのid降順で取得する
    # URL引数beforeを指定した場合、指定した値よりもidが小さいテナントの課金レポートを取得する
    get '/api/admin/tenants/billing' do
      if request.host_with_port != ENV.fetch('ISUCON_ADMIN_HOSTNAME', 'admin.t.isucon.dev')
        raise HttpError.new(404, "invalid hostname #{request.host_with_port}")
      end

      v = parse_viewer
      if v.role != ROLE_ADMIN
        raise HttpError.new(403, 'admin role required')
      end

      before = params[:before]
      before_id =
        if before
          Integer(before, 10)
        else
          nil
        end

      # テナントごとに
      #   大会ごとに
      #     scoreが登録されているplayer * 100
      #     scoreが登録されていないplayerでアクセスした人 * 10
      #   を合計したものを
      # テナントの課金とする
      tenant_billings = []

      # TODO: Remove needless columns if necessary
      # admin_db.xquery('SELECT `id`, `name`, `display_name`, `created_at`, `updated_at` FROM tenant ORDER BY id DESC').each do |row|
      #   t = TenantRow.new(row)
      #   if before_id && before_id <= t.id
      #     next
      #   end
      #   billing_yen = 0
      #   connect_to_tenant_db(t.id) do |tenant_db|
      #     tenant_db.execute('SELECT * FROM competition WHERE tenant_id=?', [t.id]) do |row|
      #       comp = CompetitionRow.new(row)
      #       report = billing_report_by_competition(tenant_db, t.id, comp.id)
      #       billing_yen += report.billing_yen
      #     end
      #   end
      #   tenant_billings.push({
      #     id: t.id.to_s,
      #     name: t.name,
      #     display_name: t.display_name,
      #     billing: billing_yen,
      #   })
      #   if tenant_billings.size >= 10
      #     break
      #   end
      # end

      # TODO: Remove needless columns if necessary
      tenants = admin_db.xquery('SELECT `id`, `name`, `display_name`, `created_at`, `updated_at` FROM tenant ORDER BY id DESC')
      ThreadHelper.trace do |tracer|
        tenant_count = 0

        tenants.each do |row|
          t = TenantRow.new(row)
          if before_id && before_id <= t.id
            next
          end

          tenant_count += 1

          break if tenant_count > 10

          tracer.trace(trace_name: "tenant_#{t.id}", thread_args: [t]) do |t|
            billing_yen = 0
            connect_to_tenant_db(t.id) do |tenant_db|
              tenant_db.execute('SELECT * FROM competition WHERE tenant_id=?', [t.id]) do |row|
                comp = CompetitionRow.new(row)
                report = billing_report_by_competition(tenant_db, t.id, comp.id)
                billing_yen += report.billing_yen
              end
            end
            tenant_billings.push(
              {
                id: t.id,
                name: t.name,
                display_name: t.display_name,
                billing: billing_yen,
              }
            )
          end
        end
      end

      tenant_billings.sort_by! { |t| -t[:id] }
      tenant_billings.each do |t|
        t[:id] = t[:id].to_s
      end

      json(
        status: true,
        data: {
          tenants: tenant_billings,
        },
      )
    end

    # テナント管理者向けAPI - 参加者追加、一覧、失格

    # 参加者一覧を返す
    get '/api/organizer/players' do
      v = parse_viewer
      if v.role != ROLE_ORGANIZER
        raise HttpError.new(403, 'role organizer required')
      end

      connect_to_tenant_db(v.tenant_id) do |tenant_db|
        players = []
        tenant_db.execute('SELECT * FROM player WHERE tenant_id=? ORDER BY created_at DESC', [v.tenant_id]) do |row|
          player = PlayerRow.new(row)
          player.is_disqualified = player.is_disqualified != 0
          players.push(player.to_h.slice(:id, :display_name, :is_disqualified))
        end

        json(
          status: true,
          data: {
            players:,
          },
        )
      end
    end

    # テナントに参加者を追加する
    post '/api/organizer/players/add' do
      v = parse_viewer
      if v.role != ROLE_ORGANIZER
        raise HttpError.new(403, 'role organizer required')
      end

      connect_to_tenant_db(v.tenant_id) do |tenant_db|
        display_names = params[:display_name]

        players = display_names.map do |display_name|
          id = dispense_id

          now = Time.now.to_i
          tenant_db.execute('INSERT INTO player (id, tenant_id, display_name, is_disqualified, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)', [id, v.tenant_id, display_name, 0, now, now])
          player = retrieve_player(tenant_db, id)
          player.to_h.slice(:id, :display_name, :is_disqualified)
        end

        json(
          status: true,
          data: {
            players:,
          },
        )
      end
    end

    # 参加者を失格にする
    post '/api/organizer/player/:player_id/disqualified' do
      v = parse_viewer
      if v.role != ROLE_ORGANIZER
        raise HttpError.new(403, 'role organizer required')
      end

      connect_to_tenant_db(v.tenant_id) do |tenant_db|
        player_id = params[:player_id]

        now = Time.now.to_i
        tenant_db.execute('UPDATE player SET is_disqualified = ?, updated_at = ? WHERE id = ?', [1, now, player_id])
        player = retrieve_player(tenant_db, player_id)
        unless player
          # 存在しないプレイヤー
          raise HttpError.new(404, 'player not found')
        end

        json(
          status: true,
          data: {
            player: player.to_h.slice(:id, :display_name, :is_disqualified),
          },
        )
      end
    end

    # テナント管理者向けAPI - 大会管理

    # 大会を追加する
    post '/api/organizer/competitions/add' do
      v = parse_viewer
      if v.role != ROLE_ORGANIZER
        raise HttpError.new(403, 'role organizer required')
      end

      connect_to_tenant_db(v.tenant_id) do |tenant_db|
        title = params[:title]

        now = Time.now.to_i
        id = dispense_id
        tenant_db.execute('INSERT INTO competition (id, tenant_id, title, finished_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)', [id, v.tenant_id, title, nil, now, now])

        json(
          status: true,
          data: {
            competition: {
              id:,
              title:,
              is_finished: false,
            },
          },
        )
      end
    end

    # 大会を終了する
    post '/api/organizer/competition/:competition_id/finish' do
      v = parse_viewer
      if v.role != ROLE_ORGANIZER
        raise HttpError.new(403, 'role organizer required')
      end

      connect_to_tenant_db(v.tenant_id) do |tenant_db|
        id = params[:competition_id]
        unless retrieve_competition(tenant_db, id)
          # 存在しない大会
          raise HttpError.new(404, 'competition not found')
        end

        now = Time.now.to_i
        tenant_db.execute('UPDATE competition SET finished_at = ?, updated_at = ? WHERE id = ?', [now, now, id])
        json(
          status: true,
        )
      end
    end

    # 大会のスコアをCSVでアップロードする
    post '/api/organizer/competition/:competition_id/score' do
      v = parse_viewer
      if v.role != ROLE_ORGANIZER
        raise HttpError.new(403, 'role organizer required')
      end

      connect_to_tenant_db(v.tenant_id) do |tenant_db|
        competition_id = params[:competition_id]
        comp = retrieve_competition(tenant_db, competition_id)
        unless comp
          # 存在しない大会
          raise HttpError.new(404, 'competition not found')
        end
        if comp.finished_at
          status 400
          return json(
            status: false,
            message: 'competition is finished',
          )
        end

        csv_file = params[:scores][:tempfile]
        csv_file.set_encoding(Encoding::UTF_8)
        csv = CSV.new(csv_file, headers: true, return_headers: true)
        csv.readline
        if csv.headers != ['player_id', 'score']
          raise HttpError.new(400, 'invalid CSV headers')
        end

        # DELETEしたタイミングで参照が来ると空っぽのランキングになるのでロックする
        flock_by_tenant_id(v.tenant_id) do
          player_score_rows = csv.map.with_index do |row, row_num|
            if row.size != 2
              raise "row must have two columns: #{row}"
            end
            player_id, score_str = *row.values_at('player_id', 'score')
            unless retrieve_player(tenant_db, player_id)
              # 存在しない参加者が含まれている
              raise HttpError.new(400, "player not found: #{player_id}")
            end
            score = Integer(score_str, 10)
            id = dispense_id
            now = Time.now.to_i
            PlayerScoreRow.new(
              id:,
              tenant_id: v.tenant_id,
              player_id:,
              competition_id:,
              score:,
              row_num:,
              created_at: now,
              updated_at: now,
            )
          end

          tenant_db.execute('DELETE FROM player_score WHERE tenant_id = ? AND competition_id = ?', [v.tenant_id, competition_id])
          player_score_rows.each do |ps|
            tenant_db.execute('INSERT INTO player_score (id, tenant_id, player_id, competition_id, score, row_num, created_at, updated_at) VALUES (:id, :tenant_id, :player_id, :competition_id, :score, :row_num, :created_at, :updated_at)', ps.to_h)
          end

          json(
            status: true,
            data: {
              rows: player_score_rows.size,
            },
          )
        end
      end
    end

    # テナント内の課金レポートを取得する
    get '/api/organizer/billing' do
      v = parse_viewer
      if v.role != ROLE_ORGANIZER
        raise HttpError.new(403, 'role organizer required')
      end

      connect_to_tenant_db(v.tenant_id) do |tenant_db|
        reports = []
        tenant_db.execute('SELECT * FROM competition WHERE tenant_id=? ORDER BY created_at DESC', [v.tenant_id]) do |row|
          comp = CompetitionRow.new(row)
          reports.push(billing_report_by_competition(tenant_db, v.tenant_id, comp.id).to_h)
        end
        json(
          status: true,
          data: {
            reports:,
          },
        )
      end
    end

    # 大会の一覧を取得する
    get '/api/organizer/competitions' do
      v = parse_viewer
      if v.role != ROLE_ORGANIZER
        raise HttpError.new(403, 'role organizer required')
      end

      connect_to_tenant_db(v.tenant_id) do |tenant_db|
        competitions_handler(v, tenant_db)
      end
    end

    # 参加者向けAPI

    # 参加者の詳細情報を取得する
    get '/api/player/player/:player_id' do
      v = parse_viewer
      if v.role != ROLE_PLAYER
        raise HttpError.new(403, 'role player required')
      end

      connect_to_tenant_db(v.tenant_id) do |tenant_db|
        authorize_player!(tenant_db, v.player_id)

        player_id = params[:player_id]
        player = retrieve_player(tenant_db, player_id)
        unless player
          raise HttpError.new(404, 'player not found')
        end
        competitions = tenant_db.execute('SELECT * FROM competition WHERE tenant_id = ? ORDER BY created_at ASC', [v.tenant_id]).map { |row| CompetitionRow.new(row) }
        # player_scoreを読んでいるときに更新が走ると不整合が起こるのでロックを取得する
        flock_by_tenant_id(v.tenant_id) do
          player_score_rows = competitions.filter_map do |c|
            # 最後にCSVに登場したスコアを採用する = row_numが一番大きいもの
            row = tenant_db.get_first_row('SELECT * FROM player_score WHERE tenant_id = ? AND competition_id = ? AND player_id = ? ORDER BY row_num DESC LIMIT 1', [v.tenant_id, c.id, player.id])
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

          json(
            status: true,
            data: {
              player: player.to_h.slice(:id, :display_name, :is_disqualified),
              scores:,
            },
          )
        end
      end
    end

    CompetitionRank = Struct.new(:rank, :score, :player_id, :player_display_name, :row_num, keyword_init: true)

    # 大会ごとのランキングを取得する
    get '/api/player/competition/:competition_id/ranking' do
      v = parse_viewer
      if v.role != ROLE_PLAYER
        raise HttpError.new(403, 'role player required')
      end

      connect_to_tenant_db(v.tenant_id) do |tenant_db|
        authorize_player!(tenant_db, v.player_id)

        competition_id = params[:competition_id]

        # 大会の存在確認
        competition = retrieve_competition(tenant_db, competition_id)
        unless competition
          raise HttpError.new(404, 'competition not found')
        end

        now = Time.now.to_i
        # tenant = TenantRow.new(admin_db.xquery('SELECT `id`, `name`, `display_name`, `created_at`, `updated_at` FROM tenant WHERE id = ?', v.tenant_id).first)
        tenant = TenantRow.new(admin_db.xquery('SELECT `id` FROM tenant WHERE id = ?', v.tenant_id).first)
        admin_db.xquery('INSERT INTO visit_history (player_id, tenant_id, competition_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?)', v.player_id, tenant.id, competition_id, now, now)

        rank_after_str = params[:rank_after]
        rank_after =
          if rank_after_str
            Integer(rank_after_str, 10)
          else
            0
          end

        # player_scoreを読んでいるときに更新が走ると不整合が起こるのでロックを取得する
        flock_by_tenant_id(v.tenant_id) do
          ranks = []
          scored_player_set = Set.new
          tenant_db.execute('SELECT * FROM player_score WHERE tenant_id = ? AND competition_id = ? ORDER BY row_num DESC', [tenant.id, competition_id]) do |row|
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

          # ranks.sort! do |a, b|
          #   if a.score == b.score
          #     a.row_num <=> b.row_num
          #   else
          #     b.score <=> a.score
          #   end
          # end

          ranks.sort_by! { |a| [-a.score, a.row_num] }

          paged_ranks = ranks.drop(rank_after).take(100).map.with_index do |rank, i|
            {
              rank: rank_after + i + 1,
              score: rank.score,
              player_id: rank.player_id,
              player_display_name: rank.player_display_name,
            }
          end

          json(
            status: true,
            data: {
              competition: {
                id: competition.id,
                title: competition.title,
                is_finished: !competition.finished_at.nil?,
              },
              ranks: paged_ranks,
            },
          )
        end
      end
    end

    # 大会の一覧を取得する
    get '/api/player/competitions' do
      v = parse_viewer
      if v.role != ROLE_PLAYER
        raise HttpError.new(403, 'role player required')
      end

      connect_to_tenant_db(v.tenant_id) do |tenant_db|
        authorize_player!(tenant_db, v.player_id)
        competitions_handler(v, tenant_db)
      end
    end

    # 全ロール及び未認証でも使えるhandler

    # JWTで認証した結果、テナントやユーザ情報を返す
    get '/api/me' do
      tenant = retrieve_tenant_row_from_header
      v =
        begin
          parse_viewer
        rescue HttpError => e
          return json(
            status: true,
            data: {
              tenant: tenant.to_h.slice(:name, :display_name),
              me: nil,
              role: ROLE_NONE,
              logged_in: false,
            },
          )
        end
      if v.role == ROLE_ADMIN|| v.role == ROLE_ORGANIZER
        json(
          status: true,
          data: {
            tenant: tenant.to_h.slice(:name, :display_name),
            me: nil,
            role: v.role,
            logged_in: true,
          },
        )
      else
        connect_to_tenant_db(v.tenant_id) do |tenant_db|
          player = retrieve_player(tenant_db, v.player_id)
          if player
            json(
              status: true,
              data: {
                tenant: tenant.to_h.slice(:name, :display_name),
                me: player.to_h.slice(:id, :display_name, :is_disqualified),
                role: v.role,
                logged_in: true,
              },
            )
          else
            json(
              status: true,
              data: {
                tenant: tenant.to_h.slice(:name, :display_name),
                me: nil,
                role: ROLE_NONE,
                logged_in: false,
              },
            )
          end
        end
      end
    end

    # ベンチマーカー向けAPI

    # ベンチマーカーが起動したときに最初に呼ぶ
    # データベースの初期化などが実行されるため、スキーマを変更した場合などは適宜改変すること
    post '/initialize' do
      out, status = Open3.capture2e(INITIALIZE_SCRIPT)
      unless status.success?
        raise HttpError.new(500, "error command execution: #{out}")
      end
      json(
        status: true,
        data: {
          lang: 'ruby',
        },
      )
    end
  end
end
