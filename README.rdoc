みずほ銀行ウェブサイトから口座残高を取得するスクリプト

2009年頃に正しく動作していることを確認しているのですが、現在は不明
たぶんUI変わってるだろうし無理

暇を見つけて今後修正していく予定なので一応githubにアップ

__
ちなみに当時の使い方は
1. Firefoxでみずほ銀行ウェブサイトにログイン
2. ./bin/cookie.plでfirefoxのsqlite3データベースからcookie情報を取得
3. そのcookie情報を元に、mizuho.rbを実行って感じです
-------------------
MizuhoBank.start(pit['username'], pit['password'], pit['aikotoba1'], pit['aikotoba2']){ |bank|
  p bank.money
}
-------------------
とすると標準出力に、口座残高が出力される

