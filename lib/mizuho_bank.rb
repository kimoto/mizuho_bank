#$KCODE='utf8'
require 'rubygems'
require 'mechanize'
require 'kconv'
require 'hpricot'
require 'nokogiri'
$KCODE = 'u'

# mechanize 0.9.3 utf8 encoding problem
WWW::Mechanize.html_parser = Hpricot

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
  TOP_URL="https://web.ib.mizuhobank.co.jp/servlet/mib?xtr=Emf00000&NLS=JP"
  DEFAULT_USER_AGENT_ALIAS='Mac FireFox'
  attr_reader :money

  def initialize(keiyaku_no, password, aikotoba1, aikotoba2, user_agent_alias=DEFAULT_USER_AGENT_ALIAS)
    @keiyaku_no = keiyaku_no.to_s
    @password = password.to_s

    @aikotoba1 = aikotoba1.to_s
    @aikotoba2 = aikotoba2.to_s

    @agent = WWW::Mechanize.new                     # インスタンス生成
    @agent.user_agent_alias = user_agent_alias.to_s
    @agent.post_connect_hooks << lambda{|p| p[:response_body] = NKF.nkf('-wm0', p[:response_body])}
  end

  def self.start(*args, &block)
    bank = nil
    begin
      bank = self.new(*args)
      bank.login
      block.call(bank)
    ensure
      bank.logout if bank
    end
  end

  def login(&block)
    auth_keiyaku_no
    auth_password

    ## goto frame2
    @agent.page.frames.last.click
    @doc = Nokogiri::HTML(@agent.page.body, nil, 'utf-8')

    p @agent.page.uri
    p index = 1

    @money = @doc.search("//body/form/center/table/tr/td/table/tr/td/table/tr/td/table/tr/td/table").to_a[index].search("div").last.inner_html.trim_no_number
  end

  def logout
    uri=@agent.page.uri
    uri.path = '/servlet/mib'
    uri.query = '?xtr=EmfLogOff&NLS=JP'
    @agent.get(uri.to_s)
  end

  private
  def auth_keiyaku_no
    @agent.get(TOP_URL){ |page|     # ページ取得
      page.form_with(:name => 'FORM1'){ |f|
        f.field_with(:name => 'KeiyakuNo').value = @keiyaku_no.tosjis
        f.click_button
      }
    }
  end

  def auth_aikotoba_1
    @agent.page.form_with(:name => 'FORM1'){ |f|
      f.field_with(:name => 'rskAns').value = @aikotoba1.tosjis
      f.click_button
    }
  end

  def auth_aikotoba_2
    @agent.page.form_with(:name => 'FORM1'){ |f|
      f.field_with(:name => 'rskAns').value = @aikotoba2.tosjis
      f.click_button
    }
  end

  def auth_password
    @agent.page.form_with(:name => 'FORM1'){ |f|
      f.field_with(:name => 'Anshu1No').value = @password.tosjis
      f.click_button
    }
  end
end
