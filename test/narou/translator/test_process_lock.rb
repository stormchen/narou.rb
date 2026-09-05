# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "yaml"
require_relative "../../../lib/narou/translator/process_lock"

class TestProcessLock < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("narou_lock_test")
    @lock = Narou::Translator::ProcessLock.new(@tmpdir)
  end

  def teardown
    @lock.release! rescue nil
    FileUtils.remove_entry(@tmpdir) if File.exist?(@tmpdir)
  end

  def test_acquire_and_release
    refute @lock.locked?
    assert @lock.acquire!
    assert @lock.locked?
    assert File.exist?(@lock.lock_path)

    lock_data = YAML.load_file(@lock.lock_path)
    assert_equal Process.pid, lock_data["pid"]

    @lock.release!
    refute @lock.locked?
    refute File.exist?(@lock.lock_path)
  end

  def test_synchronize_ensures_release
    executed = false
    @lock.synchronize do
      assert @lock.locked?
      executed = true
    end
    assert executed
    refute @lock.locked?
  end

  def test_synchronize_with_exception
    assert_raises(RuntimeError) do
      @lock.synchronize do
        assert @lock.locked?
        raise "test failure"
      end
    end
    refute @lock.locked?
  end

  def test_stale_lock_cleanup
    # 寫入一個確定不存在的幽靈 PID (9999999)
    stale_pid = 9_999_999
    stale_data = {
      "pid" => stale_pid,
      "created_at" => Time.now.to_s,
      "novel_dir" => @tmpdir
    }
    File.write(@lock.lock_path, YAML.dump(stale_data))

    # 由於 PID 9999999 不存在，acquire! 應自動識別為過期鎖並成功接管
    assert @lock.acquire!
    assert @lock.locked?

    lock_data = YAML.load_file(@lock.lock_path)
    assert_equal Process.pid, lock_data["pid"]
  end

  def test_conflict_detection_raises_error
    # 建立一個鎖，記錄目前運行的另一個活躍進程 PID
    alive_pid = Process.ppid > 0 ? Process.ppid : 4
    conflict_data = {
      "pid" => alive_pid,
      "created_at" => Time.now.to_s,
      "novel_dir" => @tmpdir
    }
    File.write(@lock.lock_path, YAML.dump(conflict_data))

    err = assert_raises(Narou::Translator::LockError) do
      @lock.acquire!
    end
    assert_includes err.message, alive_pid.to_s
  end
end
