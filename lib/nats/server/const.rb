
module NATSD #:nodoc:

  VERSION  = '0.4.22'
  APP_NAME = 'nats-server'

  DEFAULT_PORT = 4222
  DEFAULT_HOST = '0.0.0.0'

  # Parser
  AWAITING_CONTROL_LINE = 1
  AWAITING_MSG_PAYLOAD  = 2

  # Ops - See protocol.txt for more info
  # 正規表現メモ：
  #  \A : 文字列先頭。^ とは異なり改行の有無には影響しません。
  #  \s : 空白文字。[ \t\n\r\f] と同じ 
  #  \S : 非空白文字。[ \t\n\r\f] 以外の一文字。 
  #  \r : キャリッジリターン(0x0d)
  #  \d : digit, same as[0-9]
  #  \n : new line
  #   * : 直前の表現の 0 回以上の繰り返し。できるだけ長くマッチしようとする。
  #   + : 量指定子(quantifiers)。直前の表現の 1 回以上の繰り返し
  #   ? : 量指定子(quantifiers)。直前の正規表現の 0 または 1 回の繰り返し。
  #  [] : 正規表現 [ ] は、文字クラス指定です。[] 内に列挙したいずれかの一文字にマッチします。
  #          ^ : 指定した文字以外の一文字とマッチ
  #  //i : case insensitive。 正規表現オプションの一つ。
  INFO     = /\AINFO\s*\r\n/i
  PUB_OP   = /\APUB\s+([^\s]+)\s+(([^\s]+)[^\S\r\n]+)?(\d+)\r\n/i
  SUB_OP   = /\ASUB\s+([^\s]+)\s+(([^\s]+)[^\S\r\n]+)?([^\s]+)\r\n/i
  UNSUB_OP = /\AUNSUB\s+([^\s]+)\s*(\s+(\d+))?\r\n/i
  PING     = /\APING\s*\r\n/i
  PONG     = /\APONG\s*\r\n/i
  CONNECT  = /\ACONNECT\s+([^\r\n]+)\r\n/i
  UNKNOWN  = /\A(.*)\r\n/

  # RESPONSES
  CR_LF = "\r\n".freeze
  CR_LF_SIZE = CR_LF.bytesize
  EMPTY = ''.freeze
  OK = "+OK#{CR_LF}".freeze
  PING_RESPONSE = "PING#{CR_LF}".freeze
  PONG_RESPONSE = "PONG#{CR_LF}".freeze
  INFO_RESPONSE = "#{CR_LF}".freeze

  # ERR responses
  PAYLOAD_TOO_BIG     = "-ERR 'Payload size exceeded'#{CR_LF}".freeze
  PROTOCOL_OP_TOO_BIG = "-ERR 'Protocol Operation size exceeded'#{CR_LF}".freeze
  INVALID_SUBJECT     = "-ERR 'Invalid Subject'#{CR_LF}".freeze
  INVALID_SID_TAKEN   = "-ERR 'Invalid Subject Identifier (sid), already taken'#{CR_LF}".freeze
  INVALID_SID_NOEXIST = "-ERR 'Invalid Subject-Identifier (sid), no subscriber registered'#{CR_LF}".freeze
  INVALID_CONFIG      = "-ERR 'Invalid config, valid JSON required for connection configuration'#{CR_LF}".freeze
  AUTH_REQUIRED       = "-ERR 'Authorization is required'#{CR_LF}".freeze
  AUTH_FAILED         = "-ERR 'Authorization failed'#{CR_LF}".freeze
  SSL_REQUIRED        = "-ERR 'TSL/SSL is required'#{CR_LF}".freeze
  SSL_FAILED          = "-ERR 'TLS/SSL failed'#{CR_LF}".freeze
  UNKNOWN_OP          = "-ERR 'Unknown Protocol Operation'#{CR_LF}".freeze
  SLOW_CONSUMER       = "-ERR 'Slow consumer detected, connection dropped'#{CR_LF}".freeze
  UNRESPONSIVE        = "-ERR 'Unresponsive client detected, connection dropped'#{CR_LF}".freeze
  MAX_CONNS_EXCEEDED  = "-ERR 'Maximum client connections exceeded, connection dropped'#{CR_LF}".freeze

  # Pedantic Mode
  SUB = /^([^\.\*>\s]+|>$|\*)(\.([^\.\*>\s]+|>$|\*))*$/
  SUB_NO_WC = /^([^\.\*>\s]+)(\.([^\.\*>\s]+))*$/

  # Some sane default thresholds

  # 1k should be plenty since payloads sans connect string are separate
  MAX_CONTROL_LINE_SIZE = 1024

  # Should be using something different if > 1MB payload
  MAX_PAYLOAD_SIZE = (1024*1024)

  # Maximum outbound size per client
  MAX_PENDING_SIZE = (10*1024*1024)

  # Maximum pending bucket size
  MAX_WRITEV_SIZE = (64*1024)

  # Maximum connections default
  DEFAULT_MAX_CONNECTIONS = (64*1024)

  # TLS/SSL wait time
  SSL_TIMEOUT = 0.5

  # Authorization wait time
  AUTH_TIMEOUT = SSL_TIMEOUT + 0.5

  # Ping intervals
  DEFAULT_PING_INTERVAL = 120
  DEFAULT_PING_MAX = 2

  # HTTP
  RACK_JSON_HDR = { 'Content-Type' => 'application/json' }
  RACK_TEXT_HDR = { 'Content-Type' => 'text/plain' }

end
