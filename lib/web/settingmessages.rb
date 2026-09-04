# frozen_string_literal: true

#
# Copyright 2013 whiteleaf. All rights reserved.
#

module Narou
  # WEB UI > 環境設定画面で表示する各項目の説明
  # ここになければ元々の説明が表示される
  SETTING_VARIABLES_WEBUI_MESSAGES = {
    "convert.multi-device" => "同時轉換成多個裝置適用的格式。優先度高於 device。\n若只想輸出一般 EPUB 請指定 epub",
    "device" => "轉換與傳送的目標裝置",
    "difftool" => "%%ORIG%%。※WEB UI 中不使用",
    "update.sort-by" => "依指定項目順序進行更新",
    "default.title_date_align" => "enable_add_date_to_title 加入日期的顯示位置",
    "force.title_date_align" => "enable_add_date_to_title 加入日期的顯示位置",
    "difftool.arg" => "difftool 使用的參數（若未指定，則單純以新舊檔案為參數呼叫）\n" \
                      "特殊變數\n" \
                      "<b>%NEW</b> : 最新資料的差異檔案路徑\n" \
                      "<b>%OLD</b> : 舊資料的差異檔案路徑",
    "no-color" => "停用終端機彩色文字顯示\n※需重啟伺服器",
    "economy" => "容量節省相關設定",
    "send.without-freeze" => "批次傳送時排除已凍結的小說（個別傳送時即使已凍結仍可傳送）",
    "server-digest-auth.enable" => "%%ORIG%%\n※若修改 digest-auth 相關設定需重啟伺服器",
    "server-digest-auth.hashed-password" => "伺服器 Digest 認證的密碼雜湊值（Realm 為 \"narou.rb\"）。\n" \
                                            "可於 https://tgws.plus/app/digest/ 等網站產生",
    "concurrency" => "%%ORIG%% ※需重啟伺服器",
    "logging" => "%%ORIG%%\n※需重啟伺服器",
    "logging.format-filename" => "%%ORIG%%\n※需重啟伺服器",
    "logging.format-timestamp" => "%%ORIG%%\n※需重啟伺服器",
  }
end
