# encoding: utf-8
require 'mechanize'
require 'kconv'
require 'logger'
require 'retry-handler'

class MizuhoBank
  TOP_URL = "https://web.ib.mizuhobank.co.jp/servlet/mib?xtr=Emf00000"
  CACHEFLOW_URL = '/servlet/mib?xtr=Emf04000&NLS=JP'

  attr_reader :info

  def initialize(keiyaku_no, password, aikotoba_dict={}, logger=nil, &block)
    @agent = nil
    @logger = Logger.new(nil)
    @logger = logger unless logger.nil?

    if login(keiyaku_no, password, aikotoba_dict)
      block.call(self) if block_given?
    end
    self
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

    account = MizuhoAccount.new
    account.name = content.search("tr").search("./td/table")[2].search("table > tr")[3].search("table > tr > td > div")[1].text.toutf8.strip
    account.deal_type = content.search("tr").search("./td/table")[2].search("table > tr")[3].search("table > tr > td > div")[3].text.toutf8.strip
    account.number = content.search("tr").search("./td/table")[2].search("table > tr")[3].search("table > tr > td > div")[5].text.toutf8.strip
    account.money = content.search("tr").search("./td/table")[2].search("table > tr")[3].search("table > tr > td > div")[7].text.toutf8.strip
    account.usable_money = content.search("tr").search("./td/table")[2].search("table > tr")[3].search("table > tr > td > div")[9].text.toutf8.strip

    info.latest_cache_flows = []
    info.main_account = account

    records = content.search("tr").search("./td/table")[2].search("./tr/td/table/tr")[6].search("table > tr > td > div")
    10.times{ |n|
      i = (n + 1) * 4

      cacheflow = MizuhoCacheFlow.new
      cacheflow.date = records[i+0].text.toutf8.strip
      cacheflow.money_in = records[i+1].text.toutf8.strip
      cacheflow.money_out = records[i+2].text.toutf8.strip
      cacheflow.summary = records[i+3].text.toutf8.strip
      info.latest_cache_flows << cacheflow
    }
    info
  end

  def load_cacheflow_page(data)
    content = Nokogiri(data).search("#bodycontent > div > table")[4]

    account = MizuhoAccount.new
    account.name = content.search("./tr/td/table/tr/td/table/tr")[1].search("./td/table/tr/td/table/tr/td/div")[1].text.toutf8.strip
    account.deal_type = content.search("./tr/td/table/tr/td/table/tr")[1].search("./td/table/tr/td/table/tr/td/div")[3].text.toutf8.strip
    account.number = content.search("./tr/td/table/tr/td/table/tr")[1].search("./td/table/tr/td/table/tr/td/div")[5].text.toutf8.strip
    account.money = content.search("./tr/td/table/tr/td/table/tr")[1].search("./td/table/tr/td/table/tr/td/div")[7].text.toutf8.strip
    account.usable_money = content.search("./tr/td/table/tr/td/table/tr")[1].search("./td/table/tr/td/table/tr/td/div")[9].text.toutf8.strip

    account.cache_flows = []
    flows = content.search("./tr/td/table/tr/td/table/tr")[4].search("./td/table/tr/td/table/tr/td/div").map(&:text).map(&:toutf8).map(&:strip)
    (flows.size / 4 - 1).times{ |n|
      i = (n + 1) * 4
      cf = MizuhoCacheFlow.new
      (cf.date, cf.money_in, cf.money_out, cf.summary) = [flows[i], flows[i+1], flows[i+2], flows[i+3]]
      account.cache_flows << cf
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
  end

  class MizuhoCacheFlow
    attr_accessor :date
    attr_accessor :value
    attr_accessor :summary

    attr_accessor :money_in
    attr_accessor :money_out
  end

  class MizuhoAccount
    attr_accessor :name # 店名
    attr_accessor :deal_type # 取引種類
    attr_accessor :number  # 口座番号
    attr_accessor :money  # 残高
    attr_accessor :usable_money  # お引き出し可能残高
    attr_accessor :cache_flows # C/F明細
  end
end


