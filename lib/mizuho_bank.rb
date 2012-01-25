# encoding: utf-8
require 'mechanize'
require 'kconv'
require 'logger'
require 'retry-handler'
require 'moji'
require 'chronic'
require 'open-uri'
require 'pit'
require 'active_support/all'

# utility class
class String
  def trim_no_number
    self.gsub(/[^0-9]/, "")
  end
end

class Integer
  def humanize
    case 
    when self < 1000
      self
    when self < 1000000
      (self / 1000).to_s + "千円"
    when self < 1000000000
      (self / 1000000).to_s + "百万"
    end
  end
end

class MizuhoBank
  TOP_URL = "https://web.ib.mizuhobank.co.jp/servlet/mib?xtr=Emf00000"
  CACHEFLOW_URL = '/servlet/mib?xtr=Emf04000&NLS=JP'

  attr_reader :info

  def initialize(keiyaku_no, password, aikotoba_dict={}, logger=nil, &block)
    @agent = nil
    @logger = Logger.new(nil)
    @logger = logger unless logger.nil?

    unless MizuhoBank.is_available?
      raise "MizuhoBank is not available"
    end

    if login(keiyaku_no, password, aikotoba_dict)
      block.call(self) if block_given?
    end
    self
  end

  def self.new_with_pit(logger = nil, &block)
    pit = Pit.get("MizuhoBank",
                  :require => {
                    "keiyaku_no" => "keiyaku_no",
                    "password" => "password",
                    "aikotoba1_question" => "aikotoba1_question",
                    "aikotoba2_question" => "aikotoba2_question",
                    "aikotoba3_question" => "aikotoba3_question",
                    "aikotoba1_answer" => "aikotoba1_answer",
                    "aikotoba2_answer" => "aikotoba2_answer",
                    "aikotoba3_answer" => "aikotoba3_answer",
                  })

    aikotoba_dict = {
      pit['aikotoba1_question'] => pit['aikotoba1_answer'],
      pit['aikotoba2_question'] => pit['aikotoba2_answer'],
      pit['aikotoba3_question'] => pit['aikotoba3_answer']
    }
    self.new(pit['keiyaku_no'].to_s, pit['password'].to_s, aikotoba_dict, logger){ |bank|
      block.call(bank)
    }
  end

  def login(keiyaku_no, password, aikotoba_dict={})
    @login_result = false
    Proc.new do
      @agent = Mechanize.new{ |agent|
        agent.user_agent_alias = "Windows IE 7"
      }

      auth_keiyaku_no(keiyaku_no)

      while true
        page_id = what_is_this_page?
        @logger.info "page: #{page_id.inspect}"

        case page_id
        when :auth_keiyaku_no
          auth_keiyaku_no(keiyaku_no)
        when :auth_aikotoba
          aikotoba_theme = extract_aikotoba_theme
          aikotoba_answer = aikotoba_dict[aikotoba_theme]
          auth_aikotoba(aikotoba_theme, aikotoba_answer)
        when :auth_password
          auth_password(password)
        when :logout_fail_info
          raise "Logout fail info page!!"
        when :not_available_page
          raise "not available page"
        when :unknown
          @logger.info "unknown page reached: #{@agent.page.title}"
          @login_result = true

          @info = load_bank_page(@agent.page.body.toutf8)
          go_cacheflow_page
          @info.main_account = load_cacheflow_page(@agent.page.body.toutf8)
          break
        when :not_connection
          @logger.info "not connection"
        end
      end
    end.retry(:logger => @logger, :accept_exception => StandardError, :wait => 5, :max => 5)
    @login_result
  end

  def self.is_available?(time = Time.now)
    get_jikangai_ranges(time).each{ |range|
      if range.cover? time
        return false
      end
    }
    return true
  end

  class RepeatDate
    attr_accessor :wday
    attr_accessor :hour
    attr_accessor :minute

    def to_s
      if @wday.nil?
        "%02d:%02d" % [@hour, @minute]
      else
        "%s %02d:%02d" % [wday, @hour, @minute]
      end
    end
  end

  class RepeatDateRange
    attr_accessor :start
    attr_accessor :end

    def initialize
      @start = RepeatDate.new
      @end = RepeatDate.new
    end

    def cover? (time, context = Time.now)
      s = start_time(context)
      e = end_time(s)
      (s .. e).cover? (time)
    end

    def include? (*args)
      cover? *args
    end

    def start_time(context = Time.now)
      Chronic.parse(translate_in_this_month(@start.to_s, context), :now => context)
    end

    def end_time(context = Time.now)
      Chronic.parse(translate_in_this_month(@end.to_s, context), :now => context)
    end

    def translate_in_this_month(text, context=Time.now)
      if text.match(/(.*?)(.+) (.+) in this month(.*)/)
        month = context.strftime("%B")
        previous = Regexp.last_match(1)
        n = Regexp.last_match(2)
        wday = Regexp.last_match(3)
        last = Regexp.last_match(4)

        time = Chronic.parse("#{n} #{wday} in #{month}")
        time.strftime("#{previous} %Y/%m/%d #{last}")
      else
        text
      end
    end

    def to_s(context = Time.now)
      s = start_time(context)
      e = end_time(s)
      "#{s} - #{e}"
    end
  end

  def self.get_jikangai_ranges(context = Time.now)
    url = "http://www.mizuhobank.co.jp/direct/jikangai.html"
    body = open(url).read.toutf8
    doc = Nokogiri(body)
    unless body.include? "以下の時間帯は、インターネットバンキングをご利用いただけません。"
      raise "page format error"
    end

    dates = doc.search("#contents > div.section > div.inner > table :first-child > th > ul.normal > li > strong").map(&:text)

    ranges = []
    if dates.first =~ /土曜日(\d+)時(\d+)分～翌日曜日(\d+)時(\d+)分/
      range = RepeatDateRange.new
      range.start.wday = "last saturday"
      range.start.hour = Regexp.last_match(1).to_i
      range.start.minute = Regexp.last_match(2).to_i
      range.end.wday = "next sunday"
      range.end.hour = Regexp.last_match(3).to_i
      range.end.minute = Regexp.last_match(4).to_i
      ranges << range
    end

    if dates.second =~ /第1・第4土曜日(\d+)時(\d+)分～(\d+)時(\d+)分/
      range = RepeatDateRange.new
      range.start.wday = "1st saturday in this month"
      range.start.hour = Regexp.last_match(1).to_i
      range.start.minute = Regexp.last_match(2).to_i
      range.end.wday = nil
      range.end.hour = Regexp.last_match(3).to_i
      range.end.minute = Regexp.last_match(4).to_i
      ranges << range

      range = RepeatDateRange.new
      range.start.wday = "4th saturday in this month"
      range.start.hour = Regexp.last_match(1).to_i
      range.start.minute = Regexp.last_match(2).to_i
      range.end.wday = nil
      range.end.hour = Regexp.last_match(3).to_i
      range.end.minute = Regexp.last_match(4).to_i
      ranges << range
    end

    ranges
  end

  private
  # 契約者番号の認証ページ処理
  def is_auth_keiyaku_no_page?
    @agent.page.body.toutf8.include? "お客さま番号を入力し、「次へ」ボタンを"
  end

  def auth_keiyaku_no(keiyaku_no)
    @logger.info "auth_keiyaku_no: #{keiyaku_no}"
    @agent.get(TOP_URL){ |page|     # ページ取得
      unless is_auth_keiyaku_no_page?
        raise "not keiyakusya no page error"
      end

      page.form_with(:name => 'FORM1'){ |f|
        f.field_with(:name => 'KeiyakuNo').value = keiyaku_no.tosjis
        f.click_button
      }
    }
  end

  # 合言葉入力画面であるかどうか
  def is_auth_aikotoba_page?
    @agent.page.body.toutf8.include? "合言葉確認"
  end

  def extract_aikotoba_theme
    unless is_auth_aikotoba_page?
      raise "not aikotoba page error"
    end

    aikotoba_theme = Nokogiri(@agent.page.body.toutf8).search("center > :nth-child(7) > :nth-child(2) > td > div").last.text
  end

  def auth_aikotoba(aikotoba_theme, aikotoba)
    @logger.info "auth_aikotoba: #{aikotoba_theme} => #{aikotoba}"
    @agent.page.form_with(:name => 'FORM1'){ |f|
      f.field_with(:name => 'rskAns').value = aikotoba.tosjis
      f.click_button
    }
  end

  def is_auth_password_page?
    @agent.page.body.toutf8.include? "ご登録いただいている画像を確認のうえ、ログインパスワードを半角英数字で入力し"
  end

  def is_logout_fail_info_page?
    @agent.page.body.toutf8.include? "ログインできませんでした。前回の操作で正しくログアウトされていない可能性があります。"
  end

  def is_not_available_page?
    @agent.page.body.toutf8.include? "以下の時間帯は、インターネットバンキングをご利用いただけません"
  end

  def auth_password(password)
    @agent.page.form_with(:name => 'FORM1'){ |f|
      f.field_with(:name => 'Anshu1No').value = password.tosjis
      f.click_button
    }
  end

  def what_is_this_page?
    if @agent.page.nil? or @agent.page.body.nil?
      return :not_connection
    end

    if is_auth_aikotoba_page?
      return :auth_aikotoba
    elsif is_logout_fail_info_page?
      return :logout_fail_info
    elsif is_auth_password_page?
      return :auth_password
    elsif is_auth_keiyaku_no_page?
      return :auth_keiyaku_no
    elsif is_not_available_page?
      return :not_available
    else
      return :unknown
    end
  end

  def load_bank_page(page_data)
    doc = Nokogiri(page_data)
    content = doc.search("#bodycontent > div > table")[4]

    info = MizuhoDirectInfo.new
    info.username = content.search("tr > td > table > tr > td > div > b")[0].text.gsub(/さまの$/, "")
    info.last_logined_at = content.search("tr > td > table > tr > td > div > b")[2].text
    info.mailaddr = content.search("tr > td > table > tr > td > div > b")[4].text

    account_tags = content.search("tr").search("./td/table")[2].search("table > tr")[3].search("table > tr > td > div")

    info.latest_cache_flows = []
    info.main_account = MizuhoAccount.new(
      :name => account_tags[1].text.toutf8.strip,
      :deal_type => account_tags[3].text.toutf8.strip,
      :number => account_tags[5].text.toutf8.strip.trim_no_number,
      :money => account_tags[7].text.toutf8.strip.trim_no_number.to_i,
      :usable_money => account_tags[9].text.toutf8.strip.trim_no_number.to_i
    )

    records = content.search("tr").search("./td/table")[2].search("./tr/td/table/tr")[6].search("table > tr > td > div")
    10.times{ |n|
      i = (n + 1) * 4

      cacheflow = MizuhoCacheFlow.new
      cacheflow.date = Time.parse(records[i+0].text.toutf8.strip)
      cacheflow.money_in = records[i+1].text.toutf8.strip.trim_no_number.to_i
      cacheflow.money_out = records[i+2].text.toutf8.strip.trim_no_number.to_i
      cacheflow.summary = Moji.normalize_zen_han(records[i+3].text.toutf8.strip)
      info.latest_cache_flows << cacheflow
    }
    info
  end

  def load_cacheflow_page(data)
    content = Nokogiri(data).search("#bodycontent > div > table")[4]
    account_tags = content.search("./tr/td/table/tr/td/table/tr")[1].search("./td/table/tr/td/table/tr/td/div")

    account = MizuhoAccount.new(
      :name => account_tags[1].text.toutf8.strip,
      :deal_type => account_tags[3].text.toutf8.strip,
      :number => account_tags[5].text.toutf8.strip.trim_no_number.to_i,
      :money => account_tags[7].text.toutf8.strip.trim_no_number.to_i,
      :usable_money => account_tags[9].text.toutf8.strip.trim_no_number.to_i
    )

    account.cache_flows = []
    flows = content.search("./tr/td/table/tr/td/table/tr")[4].search("./td/table/tr/td/table/tr/td/div").map(&:text).map(&:toutf8).map(&:strip)
    (flows.size / 4 - 1).times{ |n|
      i = (n + 1) * 4
      account.cache_flows << MizuhoCacheFlow.new(
        :date => Time.parse(flows[i]),
        :money_out => flows[i+1].trim_no_number.to_i,
        :money_in => flows[i+2].trim_no_number.to_i,
        :summary => Moji.normalize_zen_han(flows[i+3])
      )
    }

    account
  end

  def go_cacheflow_page
    @agent.get(CACHEFLOW_URL)
    @agent.page.form_with(:name => 'FORM1'){ |f|
      f.field_with(:name => 'SelAcct'){ |list|
        list.options.first.select
      }
      f.field_with(:name => 'INQUIRY_MONTH_TYPE'){ |list|
        list.options.each{ |opt|
          if opt.value == "BEFORE_LASTMONTH"
            opt.select
          end
        }
      }
      f.click_button
    }
  end

  class MizuhoDirectInfo
    attr_accessor :username
    attr_accessor :mailaddr
    attr_accessor :last_logined_at
    attr_accessor :informations # reserved
    attr_accessor :main_account
    attr_accessor :latest_cache_flows 

    def to_s
      "#<MizuhoDirectInfo #{username} #{mailaddr} #{main_account}>"
    end
  end

  class MizuhoCacheFlow
    attr_accessor :date
    attr_accessor :summary
    attr_accessor :money_in
    attr_accessor :money_out

    def initialize(options={})
      options.each{ |key, value|
        instance_variable_set("@#{key}", value)
      }
    end

    def value
      @money_in == 0 ? -@money_out : @money_in
    end

    def to_s
      "#<MizuhoCacheFlow: #{@date.strftime("%Y/%m/%d")} #{@summary} #{self.value}>"
    end
  end

  class MizuhoAccount
    attr_accessor :name # 店名
    attr_accessor :deal_type # 取引種類
    attr_accessor :number  # 口座番号
    attr_accessor :money  # 残高
    attr_accessor :usable_money  # お引き出し可能残高
    attr_accessor :cache_flows # C/F明細

    def initialize(options={})
      options.each{ |key, value|
        instance_variable_set("@#{key}", value)
      }
    end

    def to_s
      "#<MizuhoAccount #{@name}:#{@deal_type}:#{@number} $#{@money}(#{@usable_money})>"
    end
  end
end


