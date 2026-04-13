require "dotenv/load"
require "telegram/bot"
require "webrick"
require "pty"
require "securerandom"

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
  TELEGRAM_MESSAGE_LIMIT = 4000
  TELEGRAM_MARKDOWN_V2_SPECIALS = /([\\_*\[\]()~`>#+\-=|{}.!])/

  attr_reader :dir

  def initialize(dir = Dir.pwd)
    @state = State.load
    @dir = dir
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

        Thread.new do
          loop do
            bot.api.send_chat_action(chat_id:, action: "typing")
            sleep 4.5
            break if @codex_pid.nil?
          end
        end

        stop_codex
        start_codex(message.text) do |reply|
          send_telegram_text(chat_id, reply)
        end
      end
    end
  end

  def stop_telegram_bot
    @bot.stop
  end

  def start_codex(prompt, &block)
    @codex_thread = Thread.new do
      args = [
        "codex",
        "--dangerously-bypass-approvals-and-sandbox",
        "--cd",
        dir,
        "exec",
      ]
      if (last_session_id = @state.session_ids_per_dir[dir])
        args += ["resume", last_session_id]
      end
      args << prompt

      stdout, stdin, pid = *PTY.spawn(*args)
      @codex_pid = pid

      lines = []
      codex_output = []
      first_reply = nil
      last_reply = nil
      begin
        state = :waiting_for_session_id

        stdout.each do |line|
          lines << line

          case state
          when :waiting_for_session_id
            if line.include?(SESSION_ID_INDICATOR)
              session_id = line.gsub(SESSION_ID_INDICATOR, "").gsub(/[^-\w]/, "")

              if last_session_id.nil? || (session_id && session_id != last_session_id)
                @state.session_ids_per_dir[dir] = session_id
                @state.save
              end

              state = :waiting_for_codex
            end
          when :waiting_for_codex
            if line == "\e[35m\e[3mcodex\e[0m\e[0m\r\n"
              codex_output = []
              state = :collecting_codex_output
            end
          when :collecting_codex_output
            if line.start_with?("\e")
              reply = codex_output.join.force_encoding("UTF-8")
                .sub(/\n?^diff --git .*\z/m, "").rstrip
              first_reply ||= reply
              last_reply = reply
              block.call(reply) if first_reply == reply
              state = :waiting_for_codex
            else
              codex_output << line
            end
          end
        end
      rescue Errno::EIO
      rescue => error
        STDERR.puts "#{error.class} #{error.message}\n#{error.backtrace.join("\n")}"
        block.call "Sorry, internal error: #{error.class} #{error.message}"
      end

      Process.wait(pid)
      exit_code = $?.exitstatus
      @codex_pid = nil

      if exit_code != 0
        STDERR.puts lines.join
        STDERR.puts "CODEX EXITED WITH #{exit_code}"
        block.call(last_reply || "Exited with #{exit_code}.")
      elsif last_reply && last_reply != first_reply
        block.call(last_reply)
      end
    end
  end

  def stop_codex
    @codex_thread.kill if @codex_thread
    Process.kill :TERM, @codex_pid if @codex_pid

    @codex_thread = nil
    @codex_pid = nil
  end

  def send_telegram_text(chat_id, text)
    split_telegram_message(format_telegram_markdown_v2(text)).each do |chunk|
      begin
        @bot.api.send_message(chat_id:, text: chunk, parse_mode: "MarkdownV2")
      rescue Telegram::Bot::Exceptions::ResponseError
        @bot.api.send_message(chat_id:, text: chunk, parse_mode: nil)
      end
    end
  end

  def split_telegram_message(text, limit: TELEGRAM_MESSAGE_LIMIT)
    clean_text = text.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
    return [""] if clean_text.empty?

    chunks = []
    current = +""

    clean_text.each_line(chomp: false) do |line|
      if line.length > limit
        unless current.empty?
          chunks << current
          current = +""
        end

        line.scan(/.{1,#{limit}}/m) { |piece| chunks << piece }
        next
      end

      if current.length + line.length > limit
        chunks << current
        current = +line
      else
        current << line
      end
    end

    chunks << current unless current.empty?

    return chunks if chunks.length == 1

    max_prefix_length = "(#{chunks.length}/#{chunks.length})\n".length
    body_limit = limit - max_prefix_length
    numbered_chunks = chunks.flat_map do |chunk|
      next [chunk] if chunk.length <= body_limit

      chunk.scan(/.{1,#{body_limit}}/m)
    end

    numbered_chunks.map.with_index do |chunk, index|
      "(#{index + 1}/#{numbered_chunks.length})\n#{chunk}"
    end
  end

  def format_telegram_markdown_v2(text)
    clean_text = text.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
    lines = clean_text.lines(chomp: true)

    formatted_lines = []
    in_code_block = false
    code_block_language = nil
    code_block_lines = []

    lines.each do |line|
      if in_code_block
        if line.start_with?("```")
          formatted_lines << render_code_block(code_block_lines.join("\n"), code_block_language)
          in_code_block = false
          code_block_language = nil
          code_block_lines = []
        else
          code_block_lines << line
        end
        next
      end

      if (match = line.match(/\A```([[:alnum:]_+-]*)\s*\z/))
        in_code_block = true
        code_block_language = match[1]
        code_block_lines = []
        next
      end

      formatted_lines << render_markdown_v2_line(line)
    end

    if in_code_block
      formatted_lines << render_code_block(code_block_lines.join("\n"), code_block_language)
    end

    formatted_lines.join("\n")
  end

  def render_markdown_v2_line(line)
    return "" if line.empty?

    if (match = line.match(/\A(#{Regexp.escape("-")}|\*|\+)\s+(.*)\z/))
      marker = escape_telegram_markdown_v2(match[1])
      return "#{marker} #{render_markdown_v2_inline(match[2])}"
    end

    if (match = line.match(/\A(\d+)\.\s+(.*)\z/))
      number = escape_telegram_markdown_v2(match[1])
      return "#{number}\\. #{render_markdown_v2_inline(match[2])}"
    end

    if (match = line.match(/\A#{Regexp.escape("#")}+\s+(.*)\z/))
      return "*#{render_markdown_v2_inline(match[1])}*"
    end

    render_markdown_v2_inline(line)
  end

  def render_markdown_v2_inline(text)
    tokens = []
    working = text.gsub(/`([^`\n]+)`/) do
      tokens << [:code, Regexp.last_match(1)]
      telegram_token_placeholder(tokens.length - 1)
    end

    working = working.gsub(/\*\*([^\n*][^\n]*?)\*\*/) do
      tokens << [:bold, Regexp.last_match(1)]
      telegram_token_placeholder(tokens.length - 1)
    end

    working = working.gsub(/(?<!\*)\*([^\n*][^\n]*?)\*(?!\*)/) do
      tokens << [:italic, Regexp.last_match(1)]
      telegram_token_placeholder(tokens.length - 1)
    end

    working = working.gsub(/__([^\n_][^\n]*?)__/) do
      tokens << [:underline, Regexp.last_match(1)]
      telegram_token_placeholder(tokens.length - 1)
    end

    working = working.gsub(/_([^\n_][^\n]*?)_/) do
      tokens << [:italic, Regexp.last_match(1)]
      telegram_token_placeholder(tokens.length - 1)
    end

    working = working.gsub(/~([^\n~][^\n]*?)~/) do
      tokens << [:strike, Regexp.last_match(1)]
      telegram_token_placeholder(tokens.length - 1)
    end

    escaped = escape_telegram_markdown_v2(working)
    tokens.each_with_index do |(type, value), index|
      escaped.sub!(escape_telegram_markdown_v2(telegram_token_placeholder(index)), render_telegram_token(type, value))
    end
    escaped
  end

  def render_code_block(code, language = nil)
    escaped_language = language.to_s.gsub(/[^[:alnum:]_+-]/, "")
    escaped_code = code.to_s.gsub("\\", "\\\\\\\\").gsub("`", "\\\\`")
    "```#{escaped_language}\n#{escaped_code}\n```"
  end

  def render_telegram_token(type, value)
    case type
    when :code
      "`#{value.to_s.gsub("\\", "\\\\\\\\").gsub("`", "\\\\`")}`"
    when :bold
      "*#{render_markdown_v2_inline(value)}*"
    when :italic
      "_#{render_markdown_v2_inline(value)}_"
    when :underline
      "__#{render_markdown_v2_inline(value)}__"
    when :strike
      "~#{render_markdown_v2_inline(value)}~"
    else
      escape_telegram_markdown_v2(value.to_s)
    end
  end

  def escape_telegram_markdown_v2(text)
    text.to_s.gsub(TELEGRAM_MARKDOWN_V2_SPECIALS, '\\\\\1')
  end

  def telegram_token_placeholder(index)
    "TELEGRAMTOKEN#{index}PLACEHOLDER"
  end

  # NOTE: this was an idea from the beginning that turned out to not be necessary.
  # For now, we can stream in all codex chats as Telegram chats without an MCP server.
  #
  # That said, the streaming is pretty noisy sometimes so might not be good for
  # long running tasks.
  def start_mcp_server
    mcp_server = WEBrick::HTTPServer.new(Port: 4321)

    mcp_server.mount_proc "/mcp" do |req, res|
      res.status = 200
      res["Content-Type"] = "text/plain"
      res.body = "Hello from WEBrick\n"
      # TODO: respond to jsonrpc for list tools, and for tool call
    end

    @mcp_server = mcp_server
    mcp_server.start
  end

  def stop_mcp_server
    @mcp_server&.shutdown
  end
end

##########################################################
# Command line entrypoint
##########################################################

start = proc do |dir|
  bot = Bot.new(dir)
  threads = []
  threads << Thread.new { bot.start_telegram_bot }
  # TODO: put this back if it turns out we do want MCP
  # threads << Thread.new { bot.start_mcp_server }

  stopping = false
  Signal.trap("INT") do
    if stopping
      threads.each(&:kill)
      puts "Exiting now"
      next
    end

    stopping = true
    Thread.new do
      sleep 1
      puts "Stopping gracefully"
    end

    bot.stop_codex
    bot.stop_telegram_bot
    bot.stop_mcp_server
  end
  threads.each(&:join)
end

case ARGV
in ["test"]
  bot = Bot.new
  thread = bot.start_codex "Give me a bullet point list of 5 orange things" do |reply|
    puts reply
  end
  thread.join

in ["start"]
  start.call Dir.pwd

in ["start", dir]
  start.call dir

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
