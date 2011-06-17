$LOAD_PATH<<File.join(File.dirname(__FILE__), "lib/")

require 'mizuho_bank'
require 'rubygems'
require 'pit'

pit = Pit.get("MizuhoBank", :require => {
  "username" => "keiyakusya no",
  "password" => "password",
  "aikotoba1" => "aikotoba1",
  "aikotoba2" => "aikotoba2"
})

MizuhoBank.start(pit['username'], pit['password'], pit['aikotoba1'], pit['aikotoba2']){ |bank|
  p bank.money
}
