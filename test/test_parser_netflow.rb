require 'helper'
require 'fluent/test/driver/parser'

class NetflowParserTest < Test::Unit::TestCase
  def setup
    Fluent::Test.setup
  end

  def create_parser(conf={})
    parser = Fluent::Plugin::NetflowParser.new
    parser.configure(Fluent::Config::Element.new('ROOT', '', conf, []))
    parser
  end

  test 'configure' do
    assert_nothing_raised do
      parser = create_parser
    end
  end

  test 'parse v5 binary data, dumped by netflow-generator' do
    # generated by https://github.com/mshindo/NetFlow-Generator
    parser = create_parser
    raw_data = File.binread(File.join(__dir__, "dump/netflow.v5.dump"))
    bytes_for_1record = 72
    assert_equal bytes_for_1record, raw_data.size
    parsed = []
    parser.call(raw_data) do |time, data|
      parsed << [time, data]
    end
    assert_equal 1, parsed.size
    assert_equal Time.parse('2016-02-29 11:14:00 -0800').to_i, parsed.first[0]
    expected_record = {
      # header
      "version" => 5,
      "uptime"  => 1785097000,
      "flow_records" => 1,
      "flow_seq_num" => 1,
      "engine_type" => 1,
      "engine_id"   => 1,
      "sampling_algorithm" => 0,
      "sampling_interval"  => 0,

      # record
      "ipv4_src_addr" => "10.0.0.11",
      "ipv4_dst_addr" => "20.0.0.187",
      "ipv4_next_hop" => "30.0.0.254",
      "input_snmp"  => 1,
      "output_snmp" => 2,
      "in_pkts"  => 173,
      "in_bytes" => 4581,
      "first_switched" => "2016-02-29T19:13:59.215Z",
      "last_switched"  => "2016-02-29T19:14:00.090Z",
      "l4_src_port" => 1001,
      "l4_dst_port" => 3001,
      "tcp_flags" => 27,
      "protocol" => 6,
      "src_tos"  => 0,
      "src_as"   => 101,
      "dst_as"   => 201,
      "src_mask" => 24,
      "dst_mask" => 24,
    }
    assert_equal expected_record, parsed.first[1]
  end

  DEFAULT_UPTIME = 1048383625 # == (((12 * 24 + 3) * 60 + 13) * 60 + 3) * 1000 + 625
  # 12days 3hours 13minutes 3seconds 625 milliseconds

  DEFAULT_TIME = Time.parse('2016-02-29 11:14:00 -0800').to_i
  DEFAULT_NSEC = rand(1_000_000_000)

  def msec_from_boot_to_time_by_rational(msec, uptime: DEFAULT_UPTIME, sec: DEFAULT_TIME, nsec: DEFAULT_NSEC)
    current_time = Rational(sec) + Rational(nsec, 1_000_000_000)
    diff_msec = uptime - msec
    target_time = current_time - Rational(diff_msec, 1_000)
    Time.at(target_time)
  end

  def msec_from_boot_to_time(msec, uptime: DEFAULT_UPTIME, sec: DEFAULT_TIME, nsec: DEFAULT_NSEC)
    millis = uptime - msec
    seconds = sec - (millis / 1000)
    micros = (nsec / 1000) - ((millis % 1000) * 1000)
    if micros < 0
      seconds -= 1
      micros += 1000000
    end
    Time.at(seconds, micros)
  end

  def format_for_switched(time)
    time.utc.strftime("%Y-%m-%dT%H:%M:%S.%3NZ")
  end

  test 'converting msec from boottime to time works correctly' do
    assert_equal msec_from_boot_to_time(300).to_i, msec_from_boot_to_time_by_rational(300).to_i
    assert_equal msec_from_boot_to_time(300).usec, msec_from_boot_to_time_by_rational(300).usec
  end

  test 'check performance degradation about stringifying *_switched times' do
    parser = create_parser({"switched_times_from_uptime" => true})
    data = v5_data(
      version: 5,
      flow_records: 50,
      uptime: DEFAULT_UPTIME,
      unix_sec: DEFAULT_TIME,
      unix_nsec: DEFAULT_NSEC,
      flow_seq_num: 1,
      engine_type: 1,
      engine_id: 1,
      sampling_algorithm: 0,
      sampling_interval: 0,
      records: [
        v5_record(), v5_record(), v5_record(), v5_record(), v5_record(),
        v5_record(), v5_record(), v5_record(), v5_record(), v5_record(),
        v5_record(), v5_record(), v5_record(), v5_record(), v5_record(),
        v5_record(), v5_record(), v5_record(), v5_record(), v5_record(),
        v5_record(), v5_record(), v5_record(), v5_record(), v5_record(),
        v5_record(), v5_record(), v5_record(), v5_record(), v5_record(),
        v5_record(), v5_record(), v5_record(), v5_record(), v5_record(),
        v5_record(), v5_record(), v5_record(), v5_record(), v5_record(),
        v5_record(), v5_record(), v5_record(), v5_record(), v5_record(),
        v5_record(), v5_record(), v5_record(), v5_record(), v5_record(),
      ]
    )

    bench_data = data.to_binary_s # 50 records

    # configure to leave uptime-based value as-is
    count = 0
    GC.start
    t1 = Time.now
    1000.times do
      parser.call(bench_data) do |time, record|
        # do nothing
        count += 1
      end
    end
    t2 = Time.now
    uptime_based_switched = t2 - t1

    assert{ count == 50000 }

    # make time conversion to use Rational
    count = 0
    GC.start
    t3 = Time.now
    1000.times do
      parser.call(bench_data) do |time, record|
        record["first_switched"] = format_for_switched(msec_from_boot_to_time_by_rational(record["first_switched"]))
        record["last_switched"] = format_for_switched(msec_from_boot_to_time_by_rational(record["last_switched"]))
        count += 1
      end
    end
    t4 = Time.now
    using_rational = t4 - t3

    assert{ count == 50000 }

    # skip time formatting
    count = 0
    GC.start
    t5 = Time.now
    1000.times do
      parser.call(bench_data) do |time, record|
        record["first_switched"] = msec_from_boot_to_time(record["first_switched"])
        record["last_switched"] = msec_from_boot_to_time(record["last_switched"])
        count += 1
      end
    end
    t6 = Time.now
    skip_time_formatting = t6 - t5

    assert{ count == 50000 }

    # with full time conversion (default)
    parser = create_parser
    count = 0
    GC.start
    t7 = Time.now
    1000.times do
      parser.call(bench_data) do |time, record|
        count += 1
      end
    end
    t8 = Time.now
    default_formatting = t8 - t7

    assert{ count == 50000 }

    assert{ using_rational > default_formatting }
    assert{ default_formatting > skip_time_formatting }
    assert{ skip_time_formatting > uptime_based_switched }
  end

  test 'parse v5 binary data contains 1 record, generated from definition' do
    parser = create_parser
    parsed = []

    time1 = DEFAULT_TIME
    data1 = v5_data(
      version: 5,
      flow_records: 1,
      uptime: DEFAULT_UPTIME,
      unix_sec: DEFAULT_TIME,
      unix_nsec: DEFAULT_NSEC,
      flow_seq_num: 1,
      engine_type: 1,
      engine_id: 1,
      sampling_algorithm: 0,
      sampling_interval: 0,
      records: [
        v5_record,
      ]
    )

    parser.call(data1.to_binary_s) do |time, record|
      parsed << [time, record]
    end

    assert_equal 1, parsed.size
    assert_instance_of Fluent::EventTime, parsed.first[0]
    assert_equal time1, parsed.first[0]

    event = parsed.first[1]

    assert_equal 5, event["version"]
    assert_equal 1, event["flow_records"]
    assert_equal 1, event["flow_seq_num"]
    assert_equal 1, event["engine_type"]
    assert_equal 1, event["engine_id"]
    assert_equal 0, event["sampling_algorithm"]
    assert_equal 0, event["sampling_interval"]

    assert_equal "10.0.1.122", event["ipv4_src_addr"]
    assert_equal "192.168.0.3", event["ipv4_dst_addr"]
    assert_equal "10.0.0.3", event["ipv4_next_hop"]
    assert_equal 1, event["input_snmp"]
    assert_equal 2, event["output_snmp"]
    assert_equal 156, event["in_pkts"]
    assert_equal 1024, event["in_bytes"]
    assert_equal format_for_switched(msec_from_boot_to_time(DEFAULT_UPTIME - 13000)), event["first_switched"]
    assert_equal format_for_switched(msec_from_boot_to_time(DEFAULT_UPTIME - 12950)), event["last_switched"]
    assert_equal 1048, event["l4_src_port"]
    assert_equal 80, event["l4_dst_port"]
    assert_equal 27, event["tcp_flags"]
    assert_equal 6, event["protocol"]
    assert_equal 0, event["src_tos"]
    assert_equal 101, event["src_as"]
    assert_equal 201, event["dst_as"]
    assert_equal 24, event["src_mask"]
    assert_equal 24, event["dst_mask"]
  end

  test 'parse v5 binary data contains 1 record, generated from definition, leaving switched times as using uptime' do
    parser = create_parser({"switched_times_from_uptime" => true})
    parsed = []

    time1 = DEFAULT_TIME
    data1 = v5_data(
      version: 5,
      flow_records: 1,
      uptime: DEFAULT_UPTIME,
      unix_sec: DEFAULT_TIME,
      unix_nsec: DEFAULT_NSEC,
      flow_seq_num: 1,
      engine_type: 1,
      engine_id: 1,
      sampling_algorithm: 0,
      sampling_interval: 0,
      records: [
        v5_record,
      ]
    )

    parser.call(data1.to_binary_s) do |time, record|
      parsed << [time, record]
    end

    assert_equal 1, parsed.size
    assert_equal time1, parsed.first[0]

    event = parsed.first[1]

    assert_equal 5, event["version"]
    assert_equal 1, event["flow_records"]
    assert_equal 1, event["flow_seq_num"]
    assert_equal 1, event["engine_type"]
    assert_equal 1, event["engine_id"]
    assert_equal 0, event["sampling_algorithm"]
    assert_equal 0, event["sampling_interval"]

    assert_equal "10.0.1.122", event["ipv4_src_addr"]
    assert_equal "192.168.0.3", event["ipv4_dst_addr"]
    assert_equal "10.0.0.3", event["ipv4_next_hop"]
    assert_equal 1, event["input_snmp"]
    assert_equal 2, event["output_snmp"]
    assert_equal 156, event["in_pkts"]
    assert_equal 1024, event["in_bytes"]
    assert_equal (DEFAULT_UPTIME - 13000), event["first_switched"]
    assert_equal (DEFAULT_UPTIME - 12950), event["last_switched"]
    assert_equal 1048, event["l4_src_port"]
    assert_equal 80, event["l4_dst_port"]
    assert_equal 27, event["tcp_flags"]
    assert_equal 6, event["protocol"]
    assert_equal 0, event["src_tos"]
    assert_equal 101, event["src_as"]
    assert_equal 201, event["dst_as"]
    assert_equal 24, event["src_mask"]
    assert_equal 24, event["dst_mask"]
  end

  require 'fluent/plugin/netflow_records'
  def ipv4addr(v)
    addr = Fluent::Plugin::NetflowParser::IP4Addr.new
    addr.set(v)
    addr
  end

  def ipv6addr(v)
    addr = Fluent::Plugin::NetflowParser::IP6Addr.new
    addr.set(v)
    addr
  end

  def macaddr(v)
    addr = Fluent::Plugin::NetflowParser::MacAddr.new
    addr.set(v)
    addr
  end

  def mplslabel(v)
    label = Fluent::Plugin::NetflowParser::MplsLabel.new
    label.set(v)
    label
  end

  def v5_record(hash={})
    {
      ipv4_src_addr: "10.0.1.122",
      ipv4_dst_addr: "192.168.0.3",
      ipv4_next_hop: "10.0.0.3",
      input_snmp: 1,
      output_snmp: 2,
      in_pkts: 156,
      in_bytes: 1024,
      first_switched: DEFAULT_UPTIME - 13000, # 13seconds ago
      last_switched: DEFAULT_UPTIME - 12950, # 50msec later after first switched
      l4_src_port: 1048,
      l4_dst_port: 80,
      tcp_flags: 27,
      protocol: 6,
      src_tos: 0,
      src_as: 101,
      dst_as: 201,
      src_mask: 24,
      dst_mask: 24,
    }.merge(hash)
  end

  def v5_data(hash={})
    hash = hash.dup
    hash[:records] = (hash[:records] || []).map{|r|
      r = r.dup
      [:ipv4_src_addr, :ipv4_dst_addr, :ipv4_next_hop].each do |key|
        r[key] = ipv4addr(r[key]) if r[key]
      end
      r
    }
    Fluent::Plugin::NetflowParser::Netflow5PDU.new(hash)
  end

  def v9_template(hash)
  end

  def v9_option(hash)
  end

  def v9_data(hash)
  end
end
