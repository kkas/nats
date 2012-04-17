module NATSD #:nodoc: all

  # HTTP monitorに/connzでアクセスした際にインスタンスが作成され、#callの内容が
  # JSON形式でリターンされる。
  # HTTPレスポンスを作成
  #   HTTP status = 200
  #   HTTP headers
  #   HTTP bodyとしてJSON形式のコネクション関連情報一覧
  class Connz
    def call(env)
      c_info = Server.dump_connections
      # TODO: RACKにアクセスした際のQuery文字列? ここのソート方法がよくわからない。
      qs = env['QUERY_STRING']
      if (qs =~ /n=(\d+)/)
        sort_key = :pending_size
        n = $1.to_i
        if (qs =~ /s=(\S+)/)
          case $1.downcase
            when 'in_msgs'; sort_key = :in_msgs
            when 'msgs_from'; sort_key = :in_msgs
            when 'out_msgs'; sort_key = :out_msgs
            when 'msgs_to'; sort_key = :out_msgs
            when 'in_bytes'; sort_key = :in_bytes
            when 'bytes_from'; sort_key = :in_bytes
            when 'out_bytes'; sort_key = :out_bytes
            when 'bytes_to'; sort_key = :out_bytes
            when 'subs'; sort_key = :subscriptions
            when 'subscriptions'; sort_key = :subscriptions
          end
        end
        conns = c_info[:connections]
        c_info[:connections] = conns.sort { |a,b| b[sort_key] <=> a[sort_key] } [0, n]
      end
      # 取得したコネクション関連の情報をJSONに変換、HTTP headerやステータスコードをセットし、リターンする。
      connz_json = JSON.pretty_generate(c_info) + "\n"
      hdrs = RACK_JSON_HDR.dup
      hdrs['Content-Length'] = connz_json.bytesize.to_s
      [200, hdrs, connz_json]
    end
  end

  class Server
    class << self

      def dump_connections
        conns, total = [], 0
        ObjectSpace.each_object(NATSD::Connection) do |c|
          next if c.closing?
          total += c.info[:pending_size]
          conns << c.info
        end
        {
          :pending_size => total,
          :num_connections => conns.size,
          :connections => conns
        }
      end

    end
  end

end
