# frozen_string_literal: true

require "yaml"
require "fileutils"

module Narou
  module Translator
    class LockError < StandardError; end

    # 小說翻譯專用 PID 互斥鎖管理器
    # 防止多個終端或遺留的孤兒進程同時對同一作品進行翻譯，避免 GPU 算力爭奪與快取衝突
    class ProcessLock
      LOCK_FILE_NAME = ".translate.lock"

      attr_reader :archive_path, :lock_path

      def initialize(archive_path)
        @archive_path = archive_path
        @lock_path = File.join(@archive_path, LOCK_FILE_NAME)
        @locked = false
        @at_exit_registered = false
      end

      def locked?
        @locked && File.exist?(@lock_path)
      end

      # 取得鎖定；若有其他存活進程持有鎖則拋出 LockError
      def acquire!
        return true if locked?

        if File.exist?(@lock_path)
          existing_data = load_lock_file
          existing_pid = existing_data ? existing_data["pid"].to_i : nil

          if existing_pid == Process.pid
            @locked = true
            return true
          elsif existing_pid && process_alive?(existing_pid)
            created_at = existing_data["created_at"] || "未知時間"
            raise LockError, "偵測到另一翻譯進程 (PID: #{existing_pid}，啟動於 #{created_at}) 正在處理此小說！\n" \
                             "為避免 GPU 算力搶佔與快取衝突，已阻止重複啟動。\n" \
                             "若確認該進程已失效，請手動刪除鎖定檔：#{@lock_path}"
          else
            # 殘留的過期鎖 (Stale Lock)，原進程已消亡，安全接管
            FileUtils.rm_f(@lock_path)
          end
        end

        write_lock_file
        @locked = true
        register_at_exit_hook unless @at_exit_registered

        true
      end

      # 釋放鎖定
      def release!
        return unless @locked

        if File.exist?(@lock_path)
          existing_data = load_lock_file
          # 僅釋放由當前進程建立的鎖定檔
          if existing_data.nil? || existing_data["pid"].to_i == Process.pid
            FileUtils.rm_f(@lock_path)
          end
        end
      ensure
        @locked = false
      end

      # 區塊自動管理鎖定生命週期
      def synchronize
        acquire!
        yield
      ensure
        release!
      end

      # 檢查指定 PID 是否仍在運行
      def process_alive?(pid)
        return false if pid.nil? || pid <= 0

        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      rescue StandardError
        false
      end

      private

      def load_lock_file
        YAML.load_file(@lock_path)
      rescue StandardError
        nil
      end

      def write_lock_file
        FileUtils.mkdir_p(@archive_path) unless File.directory?(@archive_path)
        data = {
          "pid" => Process.pid,
          "created_at" => Time.now.strftime("%Y-%m-%d %H:%M:%S"),
          "novel_dir" => @archive_path
        }
        File.write(@lock_path, YAML.dump(data))
      end

      def register_at_exit_hook
        @at_exit_registered = true
        at_exit do
          release! if locked?
        end
      end
    end
  end
end
