require "dotenv/load"
require "telegram/bot"
require "webrick"
require "pty"
require "securerandom"
require "debug"

STATE_PATH = "telecodex.state"

SESSION_ID_INDICATOR = "\e[1msession id:\e[0m"

PairingCode = Struct.new(:code, :user_id, :user_name, :created_at) do
  def expires_at_sec = created_at.to_i + 60 * 15
end

State = Struct.new(:paired_user_ids, :pairing_codes, :session_ids_per_dir) do
  def self.load(path = STATE_PATH)
    data = File.read(path)
    Marshal.load(data)
  rescue => e
    STDERR.puts e.inspect unless e.is_a?(Errno::ENOENT)
    new([], {}, {})
  end

  def save(path = STATE_PATH)
    File.write(path, Marshal.dump(self))
  end
end

class Bot
  def initialize
    @state = State.load
  end

  def new_pairing_code
    SecureRandom.alphanumeric(8)
  end

  def start_telegram_bot
    token = ENV.fetch("TELECODEX_BOT_TOKEN")

    Telegram::Bot::Client.run(token) do |bot|
      @bot = bot

      bot.listen do |message|
        next unless message.from
        chat_id = message.chat.id
        sender_id = message.from.id
        @state = State.load

        # Prompt for pairing if an unpaired user sent something
        unless @state.paired_user_ids.include?(sender_id)
          code = new_pairing_code
          @state.pairing_codes[code] = PairingCode.new(
            code:,
            user_id: sender_id,
            user_name: message.from.username || sender_id,
            created_at: Time.now,
          )
          @state.save

          bot.api.send_message(chat_id:, text: "Not paired.\nRun #{$0} pair #{code}")
          next
        end

        bot.api.send_chat_action(chat_id:, action: "typing")

        stop_codex
        start_codex(message.text) do |reply|
          bot.api.send_message(chat_id:, text: reply)
        end
      end
    end
  end

  def stop_telegram_bot
    # TODO: this puts never surfaces even when called
    STDERR.puts "Stopping #{@bot.inspect}"
    @bot.stop
  end

  def start_codex(prompt, &block)
    @codex_thread = Thread.new do
      args = [
        "codex",
        "--dangerously-bypass-approvals-and-sandbox",
        "exec",
      ]
      if (last_session_id = @state.session_ids_per_dir[Dir.pwd])
        args += ["resume", last_session_id]
      end
      args << prompt

      stdout, stdin, pid = *PTY.spawn(*args)
      @codex_pid = pid

      lines = []
      begin
        stdout.each { |line| lines << line }
      rescue Errno::EIO
      end

      output_start = lines.index { |l| l == "\e[35m\e[3mcodex\e[0m\e[0m\r\n" } + 1
      output = lines[output_start..-3].join

      session_id = lines
        .find { |l| l.start_with?(SESSION_ID_INDICATOR) }
        .gsub(SESSION_ID_INDICATOR, "")
        .gsub(/[^-\w]/, "")

      if session_id && session_id != last_session_id
        @state.session_ids_per_dir[Dir.pwd] = session_id
        @state.save
      end

      Process.wait(pid)
      exit_code = $?.exitstatus
      @codex_pid = nil

      if exit_code != 0
        return "Exited with #{exit_code}.\n#{lines.join}"
      end

      block.call output
    end
  end

  def stop_codex
    @codex_thread.kill if @codex_thread
    Process.kill :TERM, @codex_pid if @codex_pid

    @codex_thread = nil
    @codex_pid = nil
  end

  def start_mcp_server
    mcp_server = WEBrick::HTTPServer.new(Port: 4321)

    mcp_server.mount_proc "/mcp" do |req, res|
      res.status = 200
      res["Content-Type"] = "text/plain"
      res.body = "Hello from WEBrick\n"
      # TODO: respond to jsonrpc for list tools, and for tool call
    end

    Signal.trap("INT") { mcp_server.shutdown }

    @mcp_server = mcp_server
    mcp_server.start
  end

  def stop_mcp_server
    # TODO: this puts never surfaces even when called
    STDERR.puts "Stopping #{@mcp_server.inspect}"
    @mcp_server.shutdown
  end
end

##########################################################
# Command line entrypoint
##########################################################

case ARGV
in ["test"]
  bot = Bot.new
  puts bot.start_codex "Remind me what I last asked"

in ["start"] # TODO: directory and bot token in args??
  bot = Bot.new
  threads = []
  threads << Thread.new { bot.start_telegram_bot }
  threads << Thread.new { bot.start_mcp_server }
  Signal.trap("INT") do
    bot.stop_codex
    bot.stop_telegram_bot
    bot.stop_mcp_server
    threads.each(&:kill)
    # TODO: why does the app never terminate after this...
  end
  threads.each(&:join)

in ["pair", code]
  state = State.load
  match = state.pairing_codes[code]
  if match.nil?
    STDERR.puts "No matching code"
    exit 1
  end

  now_sec = Time.now.to_i
  if now_sec >= match.expires_at_sec
    STDERR.puts "Code expired"
    state.pairing_codes.delete code
    state.save
    exit 2
  end

  state.pairing_codes.delete code
  state.paired_user_ids << match.user_id
  state.save

  puts "Done! Authenticated user #{match.user_id}"
else
  puts "telecodex"
  puts
  puts "To start: #{$0} start"
  puts "To pair:  #{$0} pair <code>"
end

