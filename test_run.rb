# encoding: utf-8
Encoding.default_external = Encoding.default_internal = "UTF-8"
require_relative 'mizuho_bank'
require 'pit'

pit = Pit.get("MizuhoBank", :require => {
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

MizuhoBank.new(pit['keiyaku_no'].to_s, pit['password'].to_s, aikotoba_dict){ |bank|
  p bank.info.main_account.money
}

