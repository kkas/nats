# @cid:
#    ・クライアントコネクションが作成される毎に割り当てられる1から始まる番号。
#    ・作成される度にServer#cidで１ずつインクリメントされた値をセット。
#
# @subscriptions Hash:
#    ・キーはsidでSubscriberインスタンスを保持。
#
# @in_msgs:
#    ・Natsサーバがこのコネクションで受信したメッセージ総数
#    ・クライアントがpublishしたメッセージ総数と同等
#
# @out_msgs:
#    ・Natsサーバがこのコネクションに送信したメッセージ総数
#    ・クライアントがsubscribeしたメッセージ総数と同等
#
# @in_bytes:
#    ・Natsサーバがこのコネクションで受信したデータサイズの総量(byte)
#    ・クライアントがpublishしたデータサイズと同等
#
# @out_bytes:
#    ・Natsサーバがこのコネクションで送信したデータサイズの総量(byte)
#    ・クライアントがsubscribeしたデータサイズと同等
#
# @writev Array:
#    ・一時的に送信データを格納する変数。
#    ・#queue_dataで作成され、#flush_dataでクリアされる(nilをセット)
# @writev_size:
#    @writevに格納されているデータのバイトサイズを格納。
# @parse_state:
#
# @ssl_pending:
#
# @auth_pending:
#
# @ping_timer:
#    ・ping_intervalで設定された値をEM.add_periodic_timerで設定し、@ping_timerに格納。
#      #unbindでタイマーをキャンセルするために変数に格納している。
#    ・ping_intervalはオプションで設定可能。デフォルトは120秒。
#        ./lib/nats/server/const.rb:  PING_RESPONSE = "PING#{CR_LF}".freeze
#    ・lib/nats/server/options.rbで設定あり。デフォルト値は、lib/nats/server/const.rb
#
# @pings_outstanding:
#    ・コネクション作成時に０で初期化される。
#    ・クライアントに定期的にPINGメッセージを送信するたびに１ずつインクリメントされる。
#      PONGを受信したら１ずつデクリメントする。
#    ・この値がServer.ping_maxを越えた場合、クライアントコネクションが削除される。
#      コネクション削除時、クライアント側にUNRESPONSIVEの通知あり。
#            ./lib/nats/server/const.rb:  UNRESPONSIVE        = "-ERR 'Unresponsive client detected, connection dropped'#{CR_LF}".freeze
#
# @client_info:
#
# @msg_sub:
#    ・Subjectとなる文字列
#
# @msg_reply:
#    ・Replyとなる文字列? TODO:
#
# INFOメッセージ:
#    ・"INFO #{Server.info_string}#{CR_LF}"
#        Server#info_stringは@infoをJSONに変換するメソッド
#        info_stringには以下の情報が含まれる。
#               @info = {
#          :server_id => Server.id,
#          :host => host,
#          :port => port,
#          :version => VERSION,
#          :auth_required => auth_required?,
#          :ssl_required => ssl_required?,
#          :max_payload => @max_payload
#        }
module NATSD #:nodoc: all

  module Connection #:nodoc: all

    attr_accessor :in_msgs, :out_msgs, :in_bytes, :out_bytes
    attr_reader :cid, :closing, :last_activity, :writev_size
    alias :closing? :closing

    # EventMachine::Connection#send_dataを呼び出す。
    # {http://eventmachine.rubyforge.org/EventMachine/Connection.html#M000287}
    def flush_data
      return if @writev.nil? || closing?
      send_data(@writev.join)
      @writev, @writev_size = nil, 0
    end

    # 引数のデータを@writevに格納する。
    # @writev_size は@writevに溜まっているデータのバイトサイズを格納。
    # @writev_sizeがMAX_WRITEV_SIZEに達している場合はすぐに#flush_dataで
    # データを送信する。それ以外は、EM#next_tickをセットしてそこで
    # #flush_dataを呼び出してデータ送信する。
    #
    # @writevはここで作成する。作成された@writevは格納されたデータ送信後
    # (#flush_dataで送信)にnilにセットされる。また、それと同じタイミングで@writev_sizeも
    # 0にセットされる。
    def queue_data(data)
      EM.next_tick { flush_data } if @writev.nil?
      (@writev ||= []) << data
      @writev_size += data.bytesize
      flush_data if @writev_size > MAX_WRITEV_SIZE
    end

    # TODO:EM#get_peernameはSocket#unpack_sockaddr_inと一緒に使えばOK？
    # Socket#unpack_sockaddr_inは戻り値としてportとipアドレスの配列を返す。
    # {http://eventmachine.rubyforge.org/EventMachine/Connection.html#M000300}
    # {http://doc.ruby-lang.org/ja/1.9.2/library/socket.html}
    def client_info
      @client_info ||= (get_peername.nil? ? 'N/A' : Socket.unpack_sockaddr_in(get_peername))
    end

    def info
      {
        :cid => cid,
        # client_infoには、Socket#unpack_sockaddr_inの戻り値のportとipアドレスの配列が
        # 格納されている。
        # #client_info参照。
        :ip => client_info[1],
        :port => client_info[0],
        :subscriptions => @subscriptions.size,
        :pending_size => get_outbound_data_size,
        :in_msgs => @in_msgs,
        :out_msgs => @out_msgs,
        :in_bytes => @in_bytes,
        :out_bytes => @out_bytes
      }
    end

    def max_connections_exceeded?
      return false unless (Server.num_connections > Server.max_connections)
      error_close MAX_CONNS_EXCEEDED
      debug "Maximum #{Server.max_connections} connections exceeded, c:#{cid} will be closed"
      true
    end

    # Clientからのコネクションが作成された後に呼び出されるメソッド。
    # コネクションインスタンスの初期化を行う。
    # 各種変数の初期化、ping_intervalの設定など行う。
    # client側にINFOメッセージをJSON形式で送信する。
    #    INFO (
    #
    # TODO:最大コネクション数を越えている場合は、trueを返す。
    # それ以外は明示的にリターンしていないが、サーバのコネクション数をリターンしている。
    # このメソッドはEMのevent-loopで呼び出される。
    #
    # {http://eventmachine.rubyforge.org/EventMachine/Connection.html#M000268}
    def post_init
      # Server.cidではクライアントからのコネクションが作成される度にデフォルトの１から
      # １ずつインクリメントされた値が返ってくる。
      # TODO: ２からはじまる？
      @cid = Server.cid
      @subscriptions = {}
      @verbose = @pedantic = true # suppressed by most clients, but allows friendly telnet
      @in_msgs = @out_msgs = @in_bytes = @out_bytes = 0
      # @writev_size は@writevに溜まっているデータのバイトサイズを格納。
      @writev_size = 0
      # AWAITING_CONTROL_LINEは /lib/nats/server/const.rbで定義されている。
      # メッセージにこれが含まれている場合、次のデータはペイロードとなる。
      @parse_state = AWAITING_CONTROL_LINE
      send_info
      debug "Client connection created", client_info, cid
      if Server.ssl_required?
        debug "Starting TLS/SSL", client_info, cid
        flush_data
        @ssl_pending = EM.add_timer(NATSD::Server.ssl_timeout) { connect_ssl_timeout }
        start_tls(:verify_peer => true) if Server.ssl_required?
      end
      @auth_pending = EM.add_timer(NATSD::Server.auth_timeout) { connect_auth_timeout } if Server.auth_required?
      @ping_timer = EM.add_periodic_timer(NATSD::Server.ping_interval) { send_ping }
      # pingメッセージを送る度に１ずつインクリメントされる。
      # PONGを受信する度に１ずつデクリメントする。
      # Server.ping_maxを越えた場合、そのクライアントコネクションは削除される。
      @pings_outstanding = 0
      Server.num_connections += 1
      return if max_connections_exceeded?
    end

    # クライアントにpingメッセージを送信する。
    # メッセージ送信後、@pings_outstandingを１インクリメントする。
    def send_ping
      return if @closing
      if @pings_outstanding > NATSD::Server.ping_max
        error_close UNRESPONSIVE
        return
      end
      queue_data(PING_RESPONSE)
      flush_data
      @pings_outstanding += 1
    end

    def connect_auth_timeout
      error_close AUTH_REQUIRED
      debug "Connection timeout due to lack of auth credentials", cid
    end

    def connect_ssl_timeout
      error_close SSL_REQUIRED
      debug "Connection timeout due to lack of TLS/SSL negotiations", cid
    end

    # データ受信時に呼び出されるメソッド。
    # EventMachine::Connection#receive_data
    #
    # Natsプロトコル:
    #    （コントロール) + メッセージ + \n\r
    #  (nats/server/const.rb)
    #
    # コネクションはコネクション毎にステート(@parse_state)を保持しており、以下の状態が存在する。
    #    AWAITING_CONTROL_LINE :
    #        ・次に受信するデータにコントロールラインを期待している状態
    #          (nats/server/const.rb)参照
    #        ・受信したデータがNatsプロトコルとして意味のあるメッセージになるまではこのステート
    #    AWAITING_MSG_PAYLOAD :  
    #        ・Natsメッセージの送信する準備ができた状態
    #        ・メッセージをsubscriberに送信する
    def receive_data(data)
      # 受信したデータを@bufに格納していく。
      # すでに受信しているデータがある場合(@bufが存在する場合)は、連続したメッセージとして、
      # 受信したデータを末尾に追加する。
      @buf = @buf ? @buf << data : data
      return close_connection if @buf =~ /(\006|\004)/ # ctrl+c or ctrl+d for telnet friendly

      # while (@buf && !@buf.empty? && !@closing)
      while (@buf && !@closing)
        case @parse_state
        when AWAITING_CONTROL_LINE
          case @buf
          when PUB_OP
            # $&は、現在のスコープで最後に成功した正規表現のパターンマッチでマッチした文字列です。
            # 最後のマッチが失敗していた場合には nil となります。 
            ctrace('PUB OP', strip_op($&)) if NATSD::Server.trace_flag?
            return connect_auth_timeout if @auth_pending
            # $'は、現在のスコープで最後に成功した正規表現のパターンマッチでマッチした部分より後ろの文字列です。
            # 最後のマッチが失敗していた場合には nil となります。 
            @buf = $'
            @parse_state = AWAITING_MSG_PAYLOAD
            @msg_sub, @msg_reply, @msg_size = $1, $3, $4.to_i
            if (@msg_size > NATSD::Server.max_payload)
              debug_print_msg_too_big(@msg_size)
              error_close PAYLOAD_TOO_BIG
            end
            queue_data(INVALID_SUBJECT) if (@pedantic && !(@msg_sub =~ SUB_NO_WC))
          when SUB_OP
            ctrace('SUB OP', strip_op($&)) if NATSD::Server.trace_flag?
            return connect_auth_timeout if @auth_pending
            @buf = $'
            sub, qgroup, sid = $1, $3, $4
            return queue_data(INVALID_SUBJECT) if !($1 =~ SUB)
            return queue_data(INVALID_SID_TAKEN) if @subscriptions[sid]
            sub = Subscriber.new(self, sub, sid, qgroup, 0)
            @subscriptions[sid] = sub
            Server.subscribe(sub)
            queue_data(OK) if @verbose
          when UNSUB_OP
            ctrace('UNSUB OP', strip_op($&)) if NATSD::Server.trace_flag?
            return connect_auth_timeout if @auth_pending
            @buf = $'
            sid, sub = $1, @subscriptions[$1]
            if sub
              # If we have set max_responses, we will unsubscribe once we have received
              # the appropriate amount of responses.
              sub.max_responses = ($2 && $3) ? $3.to_i : nil
              delete_subscriber(sub) unless (sub.max_responses && (sub.num_responses < sub.max_responses))
              queue_data(OK) if @verbose
            else
              queue_data(INVALID_SID_NOEXIST) if @pedantic
            end
          when PING
            ctrace('PING OP', strip_op($&)) if NATSD::Server.trace_flag?
            @buf = $'
            queue_data(PONG_RESPONSE)
            flush_data
          when PONG
            ctrace('PONG OP', strip_op($&)) if NATSD::Server.trace_flag?
            @buf = $'
            @pings_outstanding -= 1
          when CONNECT
            ctrace('CONNECT OP', strip_op($&)) if NATSD::Server.trace_flag?
            @buf = $'
            begin
              config = JSON.parse($1)
              process_connect_config(config)
            rescue => e
              queue_data(INVALID_CONFIG)
              log_error
            end
          when INFO
            ctrace('INFO OP', strip_op($&)) if NATSD::Server.trace_flag?
            return connect_auth_timeout if @auth_pending
            @buf = $'
            send_info
          when UNKNOWN
            ctrace('Unknown Op', strip_op($&)) if NATSD::Server.trace_flag?
            return connect_auth_timeout if @auth_pending
            @buf = $'
            queue_data(UNKNOWN_OP)
          else
            # If we are here we do not have a complete line yet that we understand.
            # If too big, cut the connection off.
            if @buf.bytesize > NATSD::Server.max_control_line
              debug_print_controlline_too_big(@buf.bytesize)
              close_connection
            end
            return
          end
          @buf = nil if (@buf && @buf.empty?)

        when AWAITING_MSG_PAYLOAD
          return unless (@buf.bytesize >= (@msg_size + CR_LF_SIZE))
          msg = @buf.slice(0, @msg_size)
          ctrace('Processing msg', @msg_sub, @msg_reply, msg) if NATSD::Server.trace_flag?
          queue_data(OK) if @verbose
          Server.route_to_subscribers(@msg_sub, @msg_reply, msg)
          @in_msgs += 1
          @in_bytes += @msg_size
          @buf = @buf.slice((@msg_size + CR_LF_SIZE), @buf.bytesize)
          @msg_sub = @msg_size = @reply = nil
          @parse_state = AWAITING_CONTROL_LINE
          @buf = nil if (@buf && @buf.empty?)
        end
      end
    end

    # INFO メッセージを送信する。
    def send_info
      queue_data("INFO #{Server.info_string}#{CR_LF}")
    end

    def process_connect_config(config)
      @verbose  = config['verbose'] unless config['verbose'].nil?
      @pedantic = config['pedantic'] unless config['pedantic'].nil?

      return queue_data(OK) unless Server.auth_required?

      EM.cancel_timer(@auth_pending)
      if Server.auth_ok?(config['user'], config['pass'])
        queue_data(OK) if @verbose
        @auth_pending = nil
      else
        error_close AUTH_FAILED
        debug "Authorization failed for connection", cid
      end
    end

    def delete_subscriber(sub)
      ctrace('DELSUB OP', sub.subject, sub.qgroup, sub.sid) if NATSD::Server.trace_flag?
      Server.unsubscribe(sub)
      @subscriptions.delete(sub.sid)
    end

    def error_close(msg)
      queue_data(msg)
      flush_data
      EM.next_tick { close_connection_after_writing }
      @closing = true
    end

    def debug_print_controlline_too_big(line_size)
      sizes = "#{pretty_size(line_size)} vs #{pretty_size(NATSD::Server.max_control_line)} max"
      debug "Control line size exceeded (#{sizes}), closing connection.."
    end

    def debug_print_msg_too_big(msg_size)
      sizes = "#{pretty_size(msg_size)} vs #{pretty_size(NATSD::Server.max_payload)} max"
      debug "Message payload size exceeded (#{sizes}), closing connection"
    end

    def unbind
      debug "Client connection closed", client_info, cid
      Server.num_connections -= 1
      @subscriptions.each_value { |sub| Server.unsubscribe(sub) }
      EM.cancel_timer(@ssl_pending) if @ssl_pending
      @ssl_pending = nil
      EM.cancel_timer(@auth_pending) if @auth_pending
      @auth_pending = nil
      EM.cancel_timer(@ping_timer) if @ping_timer
      @ping_timer = nil

      @closing = true
    end

    def ssl_handshake_completed
      EM.cancel_timer(@ssl_pending)
      @ssl_pending = nil
      cert = get_peer_cert
      debug "Client Certificate:", cert ? cert : 'N/A', cid
    end

    # FIXME! Cert accepted by default
    def ssl_verify_peer(cert)
      true
    end

    def ctrace(*args)
      trace(args, "c: #{cid}")
    end

    def strip_op(op='')
      op.dup.sub(CR_LF, EMPTY)
    end
  end

end
