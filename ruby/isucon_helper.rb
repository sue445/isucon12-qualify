module IsuconHelper
  ROLE_ADMIN = 'admin'
  ROLE_ORGANIZER = 'organizer'
  ROLE_PLAYER = 'player'
  ROLE_NONE = 'none'
  COOKIE_NAME = 'isuports_session'

  TenantRow = Struct.new(:id, :name, :display_name, :created_at, :updated_at, keyword_init: true)
  PlayerRow = Struct.new(:tenant_id, :id, :display_name, :is_disqualified, :created_at, :updated_at, keyword_init: true)
  CompetitionRow = Struct.new(:tenant_id, :id, :title, :finished_at, :created_at, :updated_at, keyword_init: true)
  PlayerScoreRow = Struct.new(:tenant_id, :id, :player_id, :competition_id, :score, :row_num, :created_at, :updated_at, keyword_init: true)

  # アクセスしてきた人の情報
  Viewer = Struct.new(:role, :player_id, :tenant_name, :tenant_id, keyword_init: true)

  # 正しいテナント名の正規表現
  TENANT_NAME_REGEXP = /^[a-z][a-z0-9-]{0,61}[a-z0-9]$/

  TENANT_DB_SCHEMA_FILE_PATH = '../sql/tenant/10_schema.sql'

  class HttpError < StandardError
    attr_reader :code

    def initialize(code, message)
      super(message)
      @code = code
    end
  end

  # 管理用DBに接続する
  def connect_admin_db
    host = ENV.fetch('ISUCON_DB_HOST', '127.0.0.1')
    port = ENV.fetch('ISUCON_DB_PORT', '3306')
    username = ENV.fetch('ISUCON_DB_USER', 'isucon')
    password = ENV.fetch('ISUCON_DB_PASSWORD', 'isucon')
    database = ENV.fetch('ISUCON_DB_NAME', 'isuports')
    Mysql2::Client.new(
      host:,
      port:,
      username:,
      password:,
      database:,
      charset: 'utf8mb4',
      database_timezone: :utc,
      cast_booleans: true,
      symbolize_keys: true,
      reconnect: true,
    )
  end

  def admin_db
    Thread.current[:admin_db] ||= connect_admin_db
  end

  # テナントDBのパスを返す
  def tenant_db_path(id)
    tenant_db_dir = ENV.fetch('ISUCON_TENANT_DB_DIR', '../tenant_db')
    File.join(tenant_db_dir, "#{id}.db")
  end

  # テナントDBに接続する
  def connect_to_tenant_db(id, &block)
    path = tenant_db_path(id)
    ret = nil
    database_klass =
      if @trace_file_path.empty?
        SQLite3::Database
      else
        SQLite3DatabaseWithTrace
      end
    database_klass.new(path, results_as_hash: true) do |db|
      db.busy_timeout = 5000
      ret = yield(db)
    end
    ret
  end

  # テナントDBを新規に作成する
  def create_tenant_db(id)
    path = tenant_db_path(id)
    out, status = Open3.capture2e('sh', '-c', "sqlite3 #{path} < #{TENANT_DB_SCHEMA_FILE_PATH}")
    unless status.success?
      raise "failed to exec sqlite3 #{path} < #{TENANT_DB_SCHEMA_FILE_PATH}, out=#{out}"
    end
    nil
  end

  # システム全体で一意なIDを生成する
  def dispense_id
    last_exception = nil
    100.times do |i|
      begin
        admin_db.xquery('REPLACE INTO id_generator (stub) VALUES (?)', 'a')
      rescue Mysql2::Error => e
        if e.error_number == 1213 # deadlock
          last_exception = e
          next
        else
          raise e
        end
      end
      return admin_db.last_id.to_s(16)
    end
    raise last_exception
  end

  # リクエストヘッダをパースしてViewerを返す
  def parse_viewer
    token_str = cookies[COOKIE_NAME]
    unless token_str
      raise HttpError.new(401, "cookie #{COOKIE_NAME} is not found")
    end

    key_filename = ENV.fetch('ISUCON_JWT_KEY_FILE', '../public.pem')
    key_src = File.read(key_filename)
    key = OpenSSL::PKey::RSA.new(key_src)
    token, _ = JWT.decode(token_str, key, true, { algorithm: 'RS256' })
    unless token.key?('sub')
      raise HttpError.new(401, "invalid token: subject is not found in token: #{token_str}")
    end

    unless token.key?('role')
      raise HttpError.new(401, "invalid token: role is not found: #{token_str}")
    end
    role = token.fetch('role')
    unless [ROLE_ADMIN, ROLE_ORGANIZER, ROLE_PLAYER].include?(role)
      raise HttpError.new(401, "invalid token: invalid role: #{token_str}")
    end

    # aud は1要素でテナント名がはいっている
    aud = token['aud']
    if !aud.is_a?(Array) || aud.size != 1
      raise HttpError.new(401, "invalid token: aud field is few or too much: #{token_str}")
    end
    tenant = retrieve_tenant_row_from_header
    if tenant.name == 'admin' && role != ROLE_ADMIN
      raise HttpError.new(401, 'tenant not found')
    end

    if tenant.name != aud[0]
      raise HttpError.new(401, "invalid token: tenant name is not match with #{request.host_with_port}: #{token_str}")
    end
    Viewer.new(
      role:,
      player_id: token.fetch('sub'),
      tenant_name: tenant.name,
      tenant_id: tenant.id,
    )
  rescue JWT::DecodeError => e
    raise HttpError.new(401, "#{e.class}: #{e.message}")
  end

  def retrieve_tenant_row_from_header
    # JWTに入っているテナント名とHostヘッダのテナント名が一致しているか確認
    base_host = ENV.fetch('ISUCON_BASE_HOSTNAME', '.t.isucon.dev')
    tenant_name = request.host_with_port.delete_suffix(base_host)

    # SaaS管理者用ドメイン
    if tenant_name == 'admin'
      return TenantRow.new(name: 'admin', display_name: 'admin')
    end

    # テナントの存在確認
    # TODO: Remove needless columns if necessary
    tenant = admin_db.xquery('SELECT `id`, `name`, `display_name`, `created_at`, `updated_at` FROM tenant WHERE name = ?', tenant_name).first
    unless tenant
      raise HttpError.new(401, 'tenant not found')
    end
    TenantRow.new(tenant)
  end

  # 参加者を取得する
  def retrieve_player(tenant_db, id)
    row = tenant_db.get_first_row('SELECT * FROM player WHERE id = ?', [id])
    if row
      PlayerRow.new(row).tap do |player|
        player.is_disqualified = player.is_disqualified != 0
      end
    else
      nil
    end
  end

  # 参加者を認可する
  # 参加者向けAPIで呼ばれる
  def authorize_player!(tenant_db, id)
    player = retrieve_player(tenant_db, id)
    unless player
      raise HttpError.new(401, 'player not found')
    end
    if player.is_disqualified
      raise HttpError.new(403, 'player is disqualified')
    end
    nil
  end

  # 大会を取得する
  def retrieve_competition(tenant_db, id)
    row = tenant_db.get_first_row('SELECT * FROM competition WHERE id = ?', [id])
    if row
      CompetitionRow.new(row)
    else
      nil
    end
  end

  # 排他ロックのためのファイル名を生成する
  def lock_file_path(id)
    tenant_db_dir = ENV.fetch('ISUCON_TENANT_DB_DIR', '../tenant_db')
    File.join(tenant_db_dir, "#{id}.lock")
  end

  # 排他ロックする
  def flock_by_tenant_id(tenant_id, &block)
    path = lock_file_path(tenant_id)

    File.open(path, File::RDONLY | File::CREAT, 0600) do |f|
      f.flock(File::LOCK_EX)
      yield
    end
  end

  # テナント名が規則に沿っているかチェックする
  def validate_tenant_name!(name)
    unless TENANT_NAME_REGEXP.match?(name)
      raise HttpError.new(400, "invalid tenant name: #{name}")
    end
  end

  BillingReport = Struct.new(
    :competition_id,
    :competition_title,
    :player_count,  # スコアを登録した参加者数
    :visitor_count, # ランキングを閲覧だけした(スコアを登録していない)参加者数
    :billing_player_yen,  # 請求金額 スコアを登録した参加者分
    :billing_visitor_yen, # 請求金額 ランキングを閲覧だけした(スコアを登録していない)参加者分
    :billing_yen, # 合計請求金額
    keyword_init: true,
  )

  # 大会ごとの課金レポートを計算する
  def billing_report_by_competition(tenant_db, tenant_id, competition_id)
    comp = retrieve_competition(tenant_db, competition_id)

    # ランキングにアクセスした参加者のIDを取得する
    billing_map = {}
    admin_db.xquery('SELECT player_id, MIN(created_at) AS min_created_at FROM visit_history WHERE tenant_id = ? AND competition_id = ? GROUP BY player_id', tenant_id, comp.id).each do |vh|
      # competition.finished_atよりもあとの場合は、終了後に訪問したとみなして大会開催内アクセス済みとみなさない
      if comp.finished_at && comp.finished_at < vh.fetch(:min_created_at)
        next
      end
      billing_map[vh.fetch(:player_id)] = 'visitor'
    end

    # player_scoreを読んでいるときに更新が走ると不整合が起こるのでロックを取得する
    flock_by_tenant_id(tenant_id) do
      # スコアを登録した参加者のIDを取得する
      tenant_db.execute('SELECT DISTINCT(player_id) FROM player_score WHERE tenant_id = ? AND competition_id = ?', [tenant_id, comp.id]) do |row|
        pid = row.fetch('player_id')
        # スコアが登録されている参加者
        billing_map[pid] = 'player'
      end

      # 大会が終了している場合のみ請求金額が確定するので計算する
      player_count = 0
      visitor_count = 0
      if comp.finished_at
        billing_map.each_value do |category|
          case category
          when 'player'
            player_count += 1
          when 'visitor'
            visitor_count += 1
          end
        end
      end

      BillingReport.new(
        competition_id: comp.id,
        competition_title: comp.title,
        player_count:,
        visitor_count:,
        billing_player_yen: 100 * player_count, # スコアを登録した参加者は100円
        billing_visitor_yen: 10 * visitor_count,  # ランキングを閲覧だけした(スコアを登録していない)参加者は10円
        billing_yen: 100 * player_count + 10 * visitor_count,
      )
    end
  end

  def competitions_handler(v, tenant_db)
    competitions = []
    tenant_db.execute('SELECT * FROM competition WHERE tenant_id=? ORDER BY created_at DESC', [v.tenant_id]) do |row|
      comp = CompetitionRow.new(row)
      competitions.push({
        id: comp.id,
        title: comp.title,
        is_finished: !comp.finished_at.nil?,
      })
    end
    json(
      status: true,
      data: {
        competitions:,
      },
    )
  end
end
