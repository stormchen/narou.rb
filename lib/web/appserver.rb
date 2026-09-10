# frozen_string_literal: true

#
# Copyright 2013 whiteleaf. All rights reserved.
#

# rubocop:disable Metrics/ClassLength
# rubocop:disable Style/ClassAndModuleChildren

require "socket"
require "sinatra/base"
require "sinatra/json"
require "sinatra/reloader" if $development
# require "better_errors" if $debug
require "tilt/erubis"
require "tilt/haml"
require "tilt/sass"
require_relative "../commandline"
require_relative "../inventory"
require_relative "web_worker"
require_relative "pushserver"
require_relative "settingmessages"
require_relative "server_helpers"

class Narou::AppServer < Sinatra::Base
  register Sinatra::Reloader if $development
  helpers Narou::ServerHelpers

  @@request_reboot = false
  @@already_update_system = false
  @@gem_update_last_log = ""

  configure do
    set :app_file, __FILE__
    set :erb, trim: "-"
    enable :protection
    enable :sessions

    set(:version) do
      Command::Version.create_version_string
    end

    set :environment, :production unless $development
    set :server, :webrick

    if $debug
      use BetterErrors::Middleware
      BetterErrors.application_root = Narou.script_dir
    end
  end

  def self.push_server=(server)
    @@push_server = server
  end

  def self.push_server
    @@push_server
  end

  def self.request_reboot
    @@request_reboot = true
  end

  def self.request_reboot?
    @@request_reboot
  end

  #
  # サーバのアドレスを生成
  #
  # portは初回起動時にランダムで設定する。次回からは同じ設定を引き継ぐ。
  # bindは自分で設定する場合は narou s server-bind=address で行う。
  # bindは設定しなかった場合は起動したPCのプライベートIPアドレスが設定される。
  # この場合はLAN内からアクセス出来る。
  # bindがlocalhostの場合は実際には127.0.0.1で処理される。(起動したPCでしか
  # アクセス出来ない)
  # 0.0.0.0 を指定した場合はアクセスに制限がかからない（外部からアクセス可能）
  # セキュリティ上オススメ出来ない。
  #
  def self.create_address(user_port = nil)
    global_setting = Inventory.load("global_setting", :global)
    port, bind = global_setting["server-port"], global_setting["server-bind"]
    port = user_port if user_port
    ipaddress = my_ipaddress
    unless port
      port = rand(4000..65000)
      global_setting["server-port"] = port
      global_setting.save
    end
    bind = "127.0.0.1" if bind == "localhost"
    host = bind ? bind : ipaddress
    set :port, port
    set :bind, host
    {
      host: host,
      port: port
    }
  end

  #
  # 自分のIPアドレス取得
  #
  # 参考：http://qiita.com/saltheads/items/cc49fcf2af37cb277c4f
  #
  def self.my_ipaddress
    @@__ipaddress ||= -> {
      udp = UDPSocket.new
      begin
        # 128.0.0.0 への送信に使用されるNICのアドレスを取得
        udp.connect("128.0.0.0", 7)
        Socket.unpack_sockaddr_in(udp.getsockname)[1]
      rescue Errno::ENETUNREACH
        # 128.0.0.0 へのルーティングがないとき
        "127.0.0.1"
      ensure
        udp.close
      end
    }.call
  end

  def initialize
    super
    puts_hello_messages
    start_device_ejectable_event
    fill_general_all_no_in_database
    setup_server_authentication
  end

  def puts_hello_messages
    puts "<white>Narou.rb version #{Narou::VERSION}</white>".termcolor
  end

  def start_device_ejectable_event
    return unless Device.support_eject?
    Thread.new do
      loop do
        if @@push_server.connections.count > 0
          device = Narou.get_device
          @@push_server.send_all(:"device.ejectable" => device && device.ejectable?)
        end

        sleep 2
      end
    end
  end

  def general_all_no_by_toc(id)
    toc = Downloader.new(id).load_toc_file
    return nil unless toc
    toc["subtitles"].size
  end

  # 話数の設定されていない小説の話数を取得して埋める
  def fill_general_all_no_in_database
    modified = false
    Database.instance.each do |id, data|
      next if data["general_all_no"]
      data["general_all_no"] = general_all_no_by_toc(id)
      modified = true
    end
    Database.instance.save_database if modified
  end

  # サーバーの認証の設定
  # とりあえずDigest認証のみ
  def setup_server_authentication
    auth = Inventory.load("global_setting", :global).group("server-digest-auth")
    user = auth.user
    hashed = auth.hashed_password
    passwd = hashed || auth.password

    # enableかつユーザー名とパスワードが設定されている時のみ認証を有効にする
    return unless auth.enable && user && passwd

    self.class.class_exec do
      use Rack::Auth::Digest::MD5, { realm: "narou.rb", opaque: "", passwords_hashed: hashed } do |username|
        passwd if username == user
      end
    end
  end

  # ===================================================================
  # ルーティング
  # ===================================================================

  before do
    headers "Cache-Control" => "no-cache" if $development
    @bootstrap_theme = case params["webui.theme"]
                       when nil
                         Narou.theme
                       when ""   # 環境設定画面で未設定が選択された時
                         nil
                       else
                         params["webui.theme"]
                       end
    Narou::WebWorker.push_as_system_worker do
      Inventory.clear
      Database.instance.refresh
      Narou.load_global_replace_pattern
    end
  end

  get "/" do
    if params["legacy"] == "1"
      setting = Inventory.load("server_setting", :global)
      @is_first_access = !setting["already-accessed"]
      if @is_first_access
        setting["already-accessed"] = true
        setting.save
      end
      haml :index, layout: true
    else
      modern_index_path = File.join(settings.public_folder, "app", "index.html")
      if File.exist?(modern_index_path)
        send_file modern_index_path
      else
        setting = Inventory.load("server_setting", :global)
        @is_first_access = !setting["already-accessed"]
        if @is_first_access
          setting["already-accessed"] = true
          setting.save
        end
        haml :index, layout: true
      end
    end
  end

  get "/legacy" do
    setting = Inventory.load("server_setting", :global)
    @is_first_access = !setting["already-accessed"]
    if @is_first_access
      setting["already-accessed"] = true
      setting.save
    end
    haml :index, layout: true
  end

  get "/style.css" do
    scss :style
  end

  before "/settings" do
    @title = "環境設定"
    @setting_variables = Command::Setting.get_setting_variables
    @error_list = {}
    @global_replace_pattern = @replace_pattern = Narou.global_replace_pattern
  end

  post "/settings" do
    built_arguments = []
    device = params.delete("device")
    [:local, :global].each do |scope|
      @setting_variables[scope].each do |name, info|
        param_data = params[name]
        argument = ""
        if info[:type] == :boolean
          # :boolean 用のフォームデータは on, off, nil で渡される。
          # ただしチェックボックスはチェックした時だけ on が渡されるので、
          # 何もデータが無い＝off を選択したと判断する。
          # 隠しデータの場合は hidden として on, off, nil が必ず送信されるので、
          # それで判断できる。
          if param_data
            argument = convert_on_off_to_boolean(param_data).to_s
          else
            argument = "false"
          end
        elsif param_data.kind_of?(Array)
          argument = param_data.join(",")
        else
          argument = param_data
        end
        built_arguments << "#{name}=#{argument}"
      end
    end
    # device の項目だけ関連項目を変更するという挙動をするため、変更を上書き
    # されないように最後にまわす
    built_arguments << "device=#{device}" if device
    unless built_arguments.empty?
      setting = Command::Setting.new
      setting.on(:error) do |msg, name|
        if name
          @error_list[name] = msg
        end
      end
      setting.execute!(built_arguments, io: Narou::NullIO.new)
      Inventory.clear
    end

    # 置換設定保存
    params_replace_pattern = params["replace_pattern"]
    @global_replace_pattern.clear
    if params_replace_pattern.kind_of?(Array)
      params_replace_pattern.each do |pattern|
        left, right = pattern["left"].strip, pattern["right"].strip
        next if left == ""
        @global_replace_pattern << [left, right]
      end
    end
    Narou.save_global_replace_pattern

    if @error_list.empty?
      session[:alert] = [ "儲存完成", "success" ]
    else
      session[:alert] = [ "有 #{@error_list.size} 個設定項目發生錯誤", "danger" ]
    end
    redirect to "/settings"
  end

  get "/settings" do
    haml :settings
  end

  get "/help" do
    @title = "說明"
    haml :help
  end

  get "/about" do
    @narourb_version = settings.version
    @ruby_version = build_ruby_version
    haml :_about, layout: false
  end

  post "/shutdown" do
    self.class.quit!
    "伺服器已關閉。在重新啟動之前無法進行任何操作"
  end

  post "/reboot" do
    self.class.request_reboot
    self.class.quit!
    haml :_rebooting, layout: false
  end

  post "/update_system" do
    Thread.new do
      buffer = `gem update --no-document narou`
      @@gem_update_last_log = buffer.strip!
      if buffer =~ /Nothing to update\z/
        @@push_server.send_all("server.update.nothing" => buffer)
      elsif buffer.include?("Gems updated: narou")
        @@already_update_system = true
        @@push_server.send_all("server.update.success" => buffer)
      else
        @@push_server.send_all("server.update.failure" => buffer)
      end
    end
  end

  post "/gem_update_last_log" do
    content_type "text/plain"
    @@gem_update_last_log
  end

  post "/check_already_update_system" do
    json({ result: @@already_update_system })
  end

  before "/novels/:id/*" do
    @id = params[:id]
    not_found unless @id =~ /^\d+$/
    @data = Downloader.get_data_by_target(@id)
    not_found unless @data
  end

  before "/novels/:id/setting" do
    @novel_title = @data["title"]
    @title = "小說轉換設定 - #{h @novel_title}"
    @setting_variables = []
    @error_list = {}
    @novel_setting = NovelSetting.new(@id, true, true)    # 空っぽの設定を作成
    @novel_setting.settings = @novel_setting.load_setting_ini["global"]
    @original_settings = NovelSetting.get_original_settings
    @force_settings = NovelSetting.load_force_settings
    @default_settings = NovelSetting.load_default_settings
    @replace_pattern = @novel_setting.load_replace_pattern
  end

  post "/novels/:id/setting" do
    # 変換設定保存
    @original_settings.each do |info|
      name, type = info[:name], info[:type]
      param_data = params[name]
      value = nil
      begin
        if type == :boolean
          if param_data
            value = convert_on_off_to_boolean(param_data)
          else
            value = false
          end
        elsif param_data.kind_of?(Array)
          value = param_data.join(",")
        else
          if param_data.strip != ""
            value = Helper.string_cast_to_type(param_data, type)
          end
        end
        @novel_setting[name] = value
      rescue Helper::InvalidVariableType => e
        @error_list[name] = e.message
      end
    end
    @novel_setting.save_settings

    @novel_setting.replace_pattern.clear
    unless params_replace_pattern.empty?
      params_replace_pattern.each do |pattern|
        left, right = pattern["left"].strip, pattern["right"].strip
        next if left == ""
        @novel_setting.replace_pattern << [left, right]
      end
    end
    @novel_setting.save_replace_pattern

    if @error_list.empty?
      session[:alert] = [ "儲存完成", "success" ]
    else
      session[:alert] = [ "有 #{@error_list.size} 個設定項目發生錯誤", "danger" ]
    end

    haml :"novels/setting"
  end

  get "/novels/:id/setting" do
    haml :"novels/setting"
  end

  get "/novels/:id/download" do
    device = Narou.get_device
    ext = device ? device.ebook_file_ext : ".epub"
    paths = Narou.get_ebook_file_paths(@id, ext)
    if !paths.empty? && File.exist?(paths[0])
      send_file(paths[0], filename: File.basename(paths[0]), type: "application/octet-stream")
    else
      not_found
    end
  end

  get "/novels/:id/author_comments" do
    downloader = Downloader.new(@id)
    toc = downloader.load_toc_file
    @comments = []
    introductions_count = 0
    postscripts_count = 0
    toc["subtitles"].each do |sub|
      begin
        element = YAML.unsafe_load_file(downloader.section_file_path(sub))["element"]
        data_type = element["data_type"] || "text"
        introduction = element["introduction"] || ""
        postscript = element["postscript"] || ""
        if data_type == "html"
          html = HTML.new
          html.strip_decoration_tag = true
          html.string = introduction
          introduction = html.to_aozora
          html.string = postscript
          postscript = html.to_aozora
        end
        @comments.push(
          sub: sub,
          introduction: introduction,
          postscript: postscript
        )
        introductions_count += 1 unless introduction.empty?
        postscripts_count += 1 unless postscript.empty?
      rescue Errno::ENOENT
      end
    end
    total = toc["subtitles"].count.to_f
    @introductions_ratio = (introductions_count / total * 100).round(2)
    @postscripts_ratio = (postscripts_count / total * 100).round(2)
    haml :"novels/author_comments"
  end

  get "/notepad" do
    @title = "便簽記事本"
    haml :notepad
  end

  get "/edit_menu" do
    @title = "編輯自訂個別選單"
    haml :edit_menu
  end

  not_found do
    "not found"
  end

  # -------------------------------------------------------------------------------
  # API's
  # -------------------------------------------------------------------------------

  get "/api/list" do
    view_frozen = query_to_boolean(params["view_frozen"], default: true)
    view_nonfrozen = query_to_boolean(params["view_nonfrozen"], default: true)
    database_values = Database.instance.get_object.values
    json_objects = {
      draw: 1
    }
    json_objects[:data] =
      database_values.map do |data|
        id = data["id"]
        is_frozen = Narou.novel_frozen?(id)
        next nil if !view_frozen && is_frozen
        next nil if !view_nonfrozen && !is_frozen
        tags = data["tags"] || []
        {
          id: id.to_s,
          last_update: data["last_update"].to_i,
          title: escape_html(data["title"]),
          author: escape_html(data["author"]),
          sitename: data["sitename"],
          toc_url: data["toc_url"],
          novel_type: data["novel_type"] == 2 ? "短篇" : "連載",
          tags: if tags.empty?
                  ""
                else
                  %!#{decorate_tags(tags)}&nbsp;<span class="tag tag-reset label label-white"! +
                  %!data-tag="" data-toggle="tooltip" title="清除標籤搜尋">&nbsp;</span>!
                end,
          status: [
            is_frozen ? "凍結" : nil,
            tags.include?("end") ? "完結" : nil,
            tags.include?("404") ? "已刪除" : nil,
            data["suspend"] ? "中斷" : nil
          ].compact.join(", "),
          download: %!<a href="/novels/#{id}/download" class="btn btn-default btn-xs"><span class="glyphicon glyphicon-download-alt"></span></a>!,
          frozen: is_frozen,
          new_arrivals_date: data["new_arrivals_date"].tap { |m| break m.to_i if m },
          general_lastup: data["general_lastup"].tap { |m| break m.to_i if m },
          # 掲載話数
          general_all_no: data["general_all_no"],
          last_check_date: data["last_check_date"].tap { |m| break m.to_i if m },
          length: data["length"],
        }
      end.compact
    json_objects[:recordsTotal] = json_objects[:data].size
    json_objects[:recordsFiltered] = json_objects[:recordsTotal]
    json json_objects
  end

  post "/api/cancel" do
    Narou::WebWorker.cancel
    Narou::Worker.cancel if Narou.concurrency_enabled?
  end

  post "/api/convert" do
    ids = select_valid_novel_ids(params["ids"]) or pass
    opt_translate = []
    if params["translate"] == "true"
      opt_translate << "--translate"
    elsif params["translate"] == "false"
      opt_translate << "--no-translate"
    end
    if params["retranslate"] == "true"
      opt_translate << "--retranslate"
    end

    concurrency_push do
      CommandLine.run!("convert", "--no-open", *opt_translate, ids)
      @@push_server.send_all(:"table.reload")
      @@push_server.send_all(:"convert.finished" => { ids: ids })
    end
    json({ success: true, queued: true, ids: ids })
  end

  post "/api/download" do
    headers "Access-Control-Allow-Origin" => "*"
    targets = params["targets"] or error("need a parameter: `targets'")
    targets = targets.kind_of?(Array) ? targets : targets.split
    opt_mail = "--mail" if query_to_boolean(params["mail"])
    pass if targets.size == 0
    Narou::WebWorker.push do
      CommandLine.run!("download", targets, opt_mail)
      @@push_server.send_all(:"table.reload")
    end
  end

  post "/api/download_force" do
    ids = select_valid_novel_ids(params["ids"]) or pass
    Narou::WebWorker.push do
      CommandLine.run!("download", "--force", ids)
      @@push_server.send_all(:"table.reload")
    end
  end

  post "/api/mail" do
    ids = select_valid_novel_ids(params["ids"]) || []
    Narou::WebWorker.push do
      Narou.concurrency_call do
        CommandLine.run!("mail", ids, io: $stdout2)
      end
    end
  end

  post "/api/update" do
    ids = select_valid_novel_ids(params["ids"]) || []
    opt_arguments = []
    if params["force"] == "true"
      opt_arguments << "--force"
    end
    Narou::WebWorker.push do
      puts "<white>更新を開始します</white>".termcolor
      cmd = Command::Update.new
      if table_reload_timing == "every"
        cmd.on(:success) do
          @@push_server.send_all(:"table.reload")
        end
      end
      cmd.execute!(ids, opt_arguments)
      @@push_server.send_all(:"table.reload")
    end
  end

  post "/api/update_by_tag" do
    tags = params["tags"] || []
    exclusion_tags = params["exclusion_tags"] || []
    tag_params = tags.map do |tag|
      "tag:#{tag}"
    end
    tag_params += exclusion_tags.map do |tag|
      "^tag:#{tag}"
    end
    pass if tag_params.empty?
    Narou::WebWorker.push do
      cmd = Command::Update.new
      if table_reload_timing == "every"
        cmd.on(:success) do
          @@push_server.send_all(:"table.reload")
        end
      end
      cmd.execute!(tag_params)
      @@push_server.send_all(:"table.reload")
    end
  end

  post "/api/send" do
    ids = select_valid_novel_ids(params["ids"]) || []
    Narou::WebWorker.push do
      Narou.concurrency_call do
        CommandLine.run!("send", ids, io: $stdout2)
      end
    end
  end

  post "/api/backup_bookmark" do
    Narou::WebWorker.push do
      CommandLine.run!("send", "--backup-bookmark")
    end
  end

  post "/api/freeze" do
    ids = select_valid_novel_ids(params["ids"]) or pass
    Narou::WebWorker.push do
      CommandLine.run!("freeze", ids)
      @@push_server.send_all(:"table.reload")
    end
  end

  post "/api/freeze_on" do
    ids = select_valid_novel_ids(params["ids"]) or pass
    Narou::WebWorker.push do
      CommandLine.run!("freeze", "--on", ids)
      @@push_server.send_all(:"table.reload")
    end
  end

  post "/api/freeze_off" do
    ids = select_valid_novel_ids(params["ids"]) or pass
    Narou::WebWorker.push do
      CommandLine.run!("freeze", "--off", ids)
      @@push_server.send_all(:"table.reload")
    end
  end

  post "/api/remove" do
    ids = select_valid_novel_ids(params["ids"]) or pass
    opt_arguments = []
    if params["with_file"] == "true"
      opt_arguments << "--with-file"
    end
    Narou::WebWorker.push do
      CommandLine.run!("remove", "--yes", ids, opt_arguments)
      @@push_server.send_all(:"table.reload")
    end
  end

  post "/api/remove_with_file" do
    ids = select_valid_novel_ids(params["ids"]) or pass
    Narou::WebWorker.push do
      CommandLine.run!("remove", "--yes", "--with-file", ids)
      @@push_server.send_all(:"table.reload")
    end
  end

  post "/api/diff" do
    ids = select_valid_novel_ids(params["ids"]) or pass
    number = params["number"] || "1"
    disabled_log_io = $stdout.dup_with_disabled_logging
    Narou::WebWorker.push do
      # diff コマンドは１度に一つのIDしか受け取らないので一つずつ表示する
      ids.each do |id|
        # セキュリティ的にWEB UIでは独自の差分表示のみ使う
        CommandLine.run!("diff", "--no-tool", id, "--number", number)
        Helper.print_horizontal_rule(disabled_log_io)
      end
    end
  end

  get "/api/diff_list" do
    target = params["target"] or return ""
    id = Downloader.get_id_by_target(target) or return ""
    @list = Command::Diff.new.get_diff_list(id)
    haml :_diff_list, layout: false
  end

  post "/api/diff_clean" do
    target = params["target"] or pass
    id = Downloader.get_id_by_target(target) or pass
    Narou::WebWorker.push do
      CommandLine.run!("diff", "--clean", id)
    end
  end

  post "/api/inspect" do
    ids = select_valid_novel_ids(params["ids"]) or pass
    Narou::WebWorker.push do
      CommandLine.run!("inspect", ids)
    end
  end

  post "/api/folder" do
    ids = select_valid_novel_ids(params["ids"]) or pass
    CommandLine.run!("folder", ids)
  end

  post "/api/backup" do
    ids = select_valid_novel_ids(params["ids"]) or pass
    Narou::WebWorker.push do
      CommandLine.run!("backup", ids)
    end
  end

  get "/api/history" do
    case params["stream"]
    when "stdout2"
      $stdout2.string
    else
      $stdout.string
    end
  end

  post "/api/clear_history" do
    Narou::PushServer.instance.clear_history
    $stdout.string.clear
    $stdout2.string.clear if Narou.concurrency_enabled?
  end

  get "/api/tag_list" do
    result =
      +'<div><span class="tag tag-reset label label-default" data-tag="">清除標籤搜尋</span></div>' \
      '<div class="text-muted" style="font-size:10px">按住 Alt 鍵點擊可排除標籤</div>'
    tagname_list = Command::Tag.get_tag_list.keys
    tagname_list.sort.each do |tagname|
      result << "<div>#{decorate_tags([tagname])} " \
                "<span class='select-color-button' data-target-tag='#{h tagname}'>" \
                "<span class='#{Command::Tag.get_color(tagname)}'>a</span></span></div>"
    end
    result
  end

  post "/api/taginfo.json" do
    ids = select_valid_novel_ids(params["ids"]) or pass
    ids.map!(&:to_i)
    database = Database.instance
    tag_info = {}
    database.each_value do |data|
      tags = data["tags"] || []
      tags.each do |tag|
        tag_info[tag] ||= {
          count: 0,
          tag: tag,
          html: decorate_tags([tag]),
          exclusion_html: params["with_exclusion"] ? decorate_exclusion_tags([tag]) : ""
        }
        if ids.include?(data["id"])
          tag_info[tag][:count] += 1
        end
      end
    end
    json Hash[tag_info.sort_by { |k, v| k }].values
  end

  post "/api/edit_tag" do
    ids = select_valid_novel_ids(params["ids"]) or pass
    # key と value を重複を維持したまま反転
    invert_states = params["states"].inject({}) { |h,(k,v)| (h[v] ||= []) << k; h }
    invert_states.each do |state, tags|
      case state.to_i
      when 0
        # タグを削除
        Command::Tag.execute!("--delete", tags.join(" "), ids, io: Narou::NullIO.new)
      when 1
        # 現状を維持(何もしない)
      when 2
        # タグを追加
        Command::Tag.execute!("--add", tags.join(" "), ids, io: Narou::NullIO.new)
      end
    end
    @@push_server.send_all(:"table.reload")
    @@push_server.send_all(:"tag.updateCanvas")
  end

  get "/api/get_queue_size" do
    res = [
      Narou::WebWorker.instance.size, Narou::Worker.size
    ]
    json res
  end

  post "/api/update_general_lastup" do
    option = params["option"]
    option = nil if option == "all"
    is_update_modified = params["is_update_modified"] == "true"
    Narou::WebWorker.push do
      CommandLine.run!(["update", "--gl", option].compact)
      @@push_server.send_all(:"table.reload")
      @@push_server.send_all(:"tag.updateCanvas")
      if is_update_modified
        puts "<yellow>#{Narou::MODIFIED_TAG} タグの付いた小説を更新します</yellow>".termcolor
        CommandLine.run!("update", "tag:#{Narou::MODIFIED_TAG}")
        @@push_server.send_all(:"table.reload")
        @@push_server.send_all(:"tag.updateCanvas")
      end
    end
  end

  post "/api/setting_burn" do
    ids = select_valid_novel_ids(params["ids"]) or pass
    Narou::WebWorker.push do
      CommandLine.run!("setting", "--burn", ids)
    end
  end

  post "/api/change_tag_color" do
    tag = params["tag"] or pass
    color = params["color"] or pass
    tag_colors = Inventory.load("tag_colors")
    tag_colors[tag] = color
    tag_colors.save
    @@push_server.send_all(:"table.reload")
    @@push_server.send_all(:"tag.updateCanvas")
  end

  get "/api/csv/download" do
    content_type "application/csv"
    attachment "novels.csv"

    Command::Csv.new.generate
  end

  post "/api/csv/import" do
    files = params["files"] or pass
    csv = Command::Csv.new
    files.each do |file|
      csv.import(file[:tempfile])
    end
    ""
  end

  # ダウンロード登録すると同時にグレーのボタン画像を返す
  get "/api/download4ssl" do
    target = params["target"] or error("need a parameter: `target'")
    opt_mail = "--mail" if query_to_boolean(params["mail"])
    Narou::WebWorker.push do
      CommandLine.run!("download", target, opt_mail)
      @@push_server.send_all(:"table.reload")
    end
    redirect "/resources/images/dl_button1.gif"
  end

  # ダウンロード済みかどうかで表示が変わる画像
  get "/api/downloadable.gif" do
    target = params["target"]
    # 0: 未ダウンロード, 1: ダウンロード済み, 2: ダウンロード出来ない
    number =
      if target
        Downloader.get_id_by_target(target) ? 1 : 0
      else
        2
      end
    redirect "/resources/images/dl_button#{number}.gif"
  end

  get "/api/validate_url_regexp_list" do
    json SiteSetting.settings.values.map { |setting|
      Array(setting["url"]).map do |url|
        "(#{url.gsub(/\?<.+?>/, "?:").gsub("\\", "\\\\")})"
      end
    }.flatten
  end

  get "/api/version/current.json" do
    json({ version: Narou::VERSION })
  end

  get "/api/version/latest.json" do
    json({ version: Narou.latest_version })
  end

  get "/api/notepad/read" do
    content_type "text/plain"
    if File.exist?(notepad_text_path)
      File.read(notepad_text_path)
    else
      ""
    end
  end

  post "/api/notepad/save" do
    File.write(notepad_text_path, params["text"])
    @@push_server.send_all("notepad.change" => {
      text: params["text"], object_id: params["object_id"]
    })
    ""
  end

  post "/api/eject" do
    do_eject = proc do
      device = Narou.get_device
      device&.eject do
        puts "<bold><green>端末を取り外しました</green></bold>".termcolor
      end
    end
    if params["enqueue"] == "true"
      Narou::WebWorker.push do
        Narou.concurrency_call(&do_eject)
      end
    else
      do_eject.call
    end
    ""
  end

  get "/api/story" do
    id = params["id"] or pass
    toc = Downloader.get_toc_by_target(id)
    story = toc["story"] || ""
    html = HTML.new
    json title: toc["title"], story: html.ln_to_br(story.strip)
  end

  # -------------------------------------------------------------------------------
  # 現代化 UI 擴充 API (Modern Web UI APIs)
  # -------------------------------------------------------------------------------

  get "/api/system/status" do
    content_type :json
    global_setting = Inventory.load("global_setting", :global)
    local_setting = Inventory.load("local_setting", :local)
    device = Narou.get_device

    aozora_dir = global_setting["aozoraepub3dir"]
    detected_aozora = nil
    [aozora_dir, "D:/AozoraEpub3", "C:/AozoraEpub3", File.expand_path("../AozoraEpub3", Narou.root_dir)].compact.each do |dir|
      if File.exist?(File.join(dir, "AozoraEpub3.jar"))
        detected_aozora = dir.tr("\\", "/")
        break
      end
    end

    kindlegen_path = global_setting["kindlegen_path"]
    kindlegen_exists = kindlegen_path && File.exist?(kindlegen_path)

    novels_count = Database.instance.get_object.values.size

    json({
      initialized: Narou.already_init?,
      root_dir: Narou.root_dir,
      device: device ? device.name : (local_setting["device"] || "epub"),
      device_name: device ? device.display_name : "EPUB (通用格式)",
      aozoraepub3_dir: aozora_dir ? aozora_dir.tr("\\", "/") : detected_aozora,
      aozoraepub3_exists: !detected_aozora.nil?,
      kindlegen_path: kindlegen_path,
      kindlegen_exists: !!kindlegen_exists,
      novels_count: novels_count,
      ruby_version: RUBY_VERSION,
      narou_version: Narou::VERSION,
      server_port: settings.port,
      line_height: local_setting["line-height"] || 1.8,
      os: RUBY_PLATFORM,
      # 翻譯與 AI 模型設定
      translate_enable: global_setting["translate.enable"] == true,
      translate_engine: global_setting["translate.engine"] || "openai",
      translate_endpoint: global_setting["translate.endpoint"] || "http://localhost:11434/v1",
      translate_model: global_setting["translate.model"] || "sakura-best",
      translate_api_key: global_setting["translate.api_key"] || "",
      translate_chunk_size: global_setting["translate.chunk_size"] || 600,
      translate_max_retries: global_setting["translate.max_retries"] || 3
    })
  end

  post "/api/system/setup" do
    content_type :json
    payload = request.body.size > 0 ? (JSON.parse(request.body.read) rescue params) : params
    device_name = payload["device"]
    aozora_dir = payload["aozoraepub3_dir"]
    line_height = payload["line_height"]
    global_setting = Inventory.load("global_setting", :global)

    built_args = []
    if device_name && !device_name.empty?
      built_args << "device=#{device_name}"
    end
    if aozora_dir && !aozora_dir.empty? && File.exist?(aozora_dir)
      global_setting["aozoraepub3dir"] = aozora_dir.tr("\\", "/")
      global_setting.save
    end
    if line_height
      local_setting = Inventory.load("local_setting", :local)
      local_setting["line-height"] = line_height.to_f
      local_setting.save
    end

    # 儲存翻譯與 AI 模型設定
    ["translate.enable", "translate.engine", "translate.endpoint", "translate.model", "translate.api_key", "translate.chunk_size", "translate.max_retries"].each do |key|
      field = key.sub(".", "_")
      if payload.key?(field)
        val = payload[field]
        val = (val == true || val == "true") if key == "translate.enable"
        val = val.to_i if key == "translate.chunk_size" || key == "translate.max_retries"
        global_setting[key] = val
        global_setting.save
      end
    end

    unless built_args.empty?
      setting = Command::Setting.new
      setting.execute!(built_args, io: Narou::NullIO.new)
      Inventory.clear
    end

    unless Narou.already_init?
      Narou.init
    end

    json({ success: true, message: "系統設定已更新完成" })
  end

  post "/api/translate/test" do
    content_type :json
    payload = request.body.size > 0 ? (JSON.parse(request.body.read) rescue params) : params
    engine_type = (payload["engine"] || "openai").to_s.downcase
    opts = {
      endpoint: payload["endpoint"],
      api_key: payload["api_key"],
      model: payload["model"],
      chunk_size: 200,
      max_retries: 0
    }.compact

    begin
      require_relative "../narou/translator"
      engine = case engine_type
               when "gemini"
                 Narou::Translator::GeminiEngine.new(opts)
               when "web"
                 Narou::Translator::WebEngine.new(opts)
               else
                 Narou::Translator::OpenAIEngine.new(opts)
               end
      test_text = "こんにちは、世界！"
      require "timeout"
      translated = Timeout.timeout(5) do
        engine.translate(test_text)
      end
      if translated && !translated.strip.empty?
        json({ success: true, source: test_text, translated: translated.strip, engine: engine_type })
      else
        json({ success: false, error: "翻譯結果為空" })
      end
    rescue Timeout::Error
      json({ success: false, error: "連線逾時 (5秒)，請檢查端點 URL 是否正確，或本機 Ollama 服務是否已啟動。" })
    rescue => e
      json({ success: false, error: e.message })
    end
  end

  post "/api/novels/batch" do
    content_type :json
    payload = request.body.size > 0 ? (JSON.parse(request.body.read) rescue params) : params
    action = payload["action"]
    ids = Array(payload["ids"]).map(&:to_s).reject(&:empty?)

    case action
    when "download"
      targets = Array(payload["targets"]).map(&:to_s).reject(&:empty?)
      if targets.empty? && payload["target"]
        targets = payload["target"].to_s.split
      end
      if targets.any?
        opt_mail = payload["mail"] ? "--mail" : nil
        Narou::WebWorker.push do
          CommandLine.run!(["download", *targets, opt_mail].compact)
          @@push_server.send_all(:"table.reload")
        end
      end
    when "update"
      force = payload["force"] ? ["--force"] : []
      Narou::WebWorker.push do
        CommandLine.run!(["update", *force, *ids])
        @@push_server.send_all(:"table.reload")
      end
    when "convert"
      opt_translate = []
      if payload["translate"] == true || payload["translate"] == "true"
        opt_translate << "--translate"
      elsif payload["translate"] == false || payload["translate"] == "false"
        opt_translate << "--no-translate"
      end
      if payload["retranslate"] == true || payload["retranslate"] == "true"
        opt_translate << "--retranslate"
      end

      concurrency_push do
        CommandLine.run!(["convert", "--no-open", *opt_translate, *ids])
        @@push_server.send_all(:"table.reload")
        @@push_server.send_all(:"convert.finished" => { ids: ids })
      end
    when "send"
      concurrency_push do
        CommandLine.run!(["send", *ids])
      end
    when "freeze_on"
      ids.each { |id| Narou.novel_freeze!(id, true) }
      @@push_server.send_all(:"table.reload")
    when "freeze_off"
      ids.each { |id| Narou.novel_freeze!(id, false) }
      @@push_server.send_all(:"table.reload")
    when "remove"
      Narou::WebWorker.push do
        CommandLine.run!(["remove", "-y", *ids])
        @@push_server.send_all(:"table.reload")
      end
    when "remove_with_file"
      Narou::WebWorker.push do
        CommandLine.run!(["remove", "-y", "--with-file", *ids])
        @@push_server.send_all(:"table.reload")
      end
    end

    json({ success: true, action: action, count: ids.size })
  end

  # -------------------------------------------------------------------------------
  # 一部分に表示するためのHTMLを取得する(パーシャル)
  # -------------------------------------------------------------------------------

  get "/partial/csv_import" do
    haml :"partial/csv_import", layout: false
  end

  get "/partial/download_form" do
    haml :"partial/download_form", layout: false
  end

  # -------------------------------------------------------------------------------
  # ウィジット関係
  # -------------------------------------------------------------------------------

  BOOKMARKLET_MODE = %w(download insert_button)

  get "/js/widget.js" do
    @params = params
    if BOOKMARKLET_MODE.include?(params["mode"])
      content_type :js
      erb :"bookmarklet/#{params['mode']}.js"
    else
      error("invaid mode")
    end
  end

  ALLOW_HOSTS = [].tap do |hosts|
    SiteSetting.settings.each_value do |s|
      hosts << s["domain"]
    end
    hosts.freeze
  end

  before "/widget/*" do
    from = params["from"]
    if ALLOW_HOSTS.include?(from)
      headers "X-Frame-Options" => "ALLOW-FROM http://#{from}/"
    end
  end

  get "/widget/download" do
    target = params["target"] or error("targetを指定して下さい")
    mail = query_to_boolean(params["mail"]) ? "--mail" : nil
    Narou::WebWorker.push do
      CommandLine.run!("download", target, mail)
      @@push_server.send_all(:"table.reload")
    end
    haml :"widget/download", layout: nil
  end

  get "/widget/drag_and_drop" do
    haml :"widget/drag_and_drop", layout: nil
  end

  get "/widget/notepad" do
    haml :"widget/notepad", layout: nil
  end
end
