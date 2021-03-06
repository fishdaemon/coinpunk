class IndexController < Controller
  get '/' do
    dashboard_if_signed_in
    slim :index
  end

  get '/dashboard' do
    require_login

    @title = 'Dashboard'

    account = Account[email: session[:account_email]]

    addresses_raw, transactions_raw, account_balance_raw = $bitcoin.batch do |client|
      client.rpc 'getaddressesbyaccount', account.email
      client.rpc 'listtransactions', account.email
      client.rpc 'getbalance', account.email
    end

    @addresses_received = $bitcoin.batch do
      addresses_raw['result'].each {|a| rpc 'getreceivedbyaddress', a}
    end.collect{|a| a['result']}

    @account            = account
    @addresses          = addresses_raw['result']
    @transactions       = transactions_raw['result']
    @account_balance    = account_balance_raw['result']

    slim :dashboard
  end

  post '/send' do
    require_login

    if params[:to_address].match Account::EMAIL_VALIDATION_REGEX
      # receiving_address = bitcoin_rpc 'getaccountaddress', params[:to_address]
      @temporary_password = Pwqgen.new.generate 2
      @account = create_account params[:to_address], @temporary_password, true
      @sending_email = session[:account_email]
      @amount = params[:amount]
      @comment = params[:comment]
      @url = request.url_without_path

      transaction_id = bitcoin_rpc(
        'sendfrom',
        session[:account_email],
        @account.receive_addresses.first.bitcoin_address,
        params[:amount].to_f,
        0,
        params[:comment],
        params[:'comment-to']
      )

      EmailSendWorker.perform_async({
        from: CONFIG['email_from'],
        to: params[:to_address],
        subject: "You have just received Bitcoins!",
        html_part: slim(:email_sent_bitcoins, layout: false)
      })

      flash[:success] = "Sent #{params[:amount]} BTC to #{params[:to_address]}."

      redirect '/dashboard'
    end

    # sending to bitcoin address
    begin
      transaction_id = bitcoin_rpc(
        'sendfrom',
        session[:account_email],
        params[:to_address],
        params[:amount].to_f,
        MINIMUM_SEND_CONFIRMATIONS,
        params[:comment],
        params[:'comment-to']
      )
    rescue Silkroad::Client::Error => e
      flash[:error] = "Unable to send bitcoins: #{e.message}"
      redirect '/dashboard'
    end

    flash[:success] = "Sent #{params[:amount]} BTC to #{params[:to_address]}."
    redirect '/dashboard'
  end

  get '/transaction/:txid' do
    require_login
    @transaction = bitcoin_rpc 'gettransaction', params[:txid]
    slim :'transactions/view'
  end

  get '/accounts/new' do
    dashboard_if_signed_in
    @account = Account.new
    slim :'accounts/new'
  end

  post '/accounts/signin' do
    if (Account.valid_login?(params[:email], params[:password]))
      session[:account_email] = params[:email]

      if current_account.temporary_password
        session[:temporary_password] = true
        redirect '/accounts/change_temporary_password'
      end

      redirect '/dashboard'
    else
      flash[:error] = 'Invalid login.'
      redirect '/'
    end
  end

  get '/accounts/change_temporary_password' do
    slim :'accounts/change_temporary_password'
  end

  post '/accounts/change_temporary_password' do
    current_account.password = params[:password]

    if current_account.valid?
      current_account.temporary_password = false
      current_account.save
      session[:temporary_password] = false
      flash[:success] = 'Temporary password changed. Welcome to Coinpunk!'
      redirect '/dashboard'
    else
      slim :'accounts/change_temporary_password'
    end
  end

  post '/accounts/create' do
    dashboard_if_signed_in

    @account = create_account params[:email], params[:password]

    if @account.new? # invalid
      slim :'accounts/new'
    else
      session[:account_email] = @account.email
      flash[:success] = 'Account successfully created!'
      redirect '/dashboard'
    end
  end

  post '/addresses/create' do
    require_login
    address = bitcoin_rpc 'getnewaddress', session[:account_email]
    Account[email: session[:account_email]].add_receive_address name: params[:name], bitcoin_address: address
    flash[:success] = "Created new receive address \"#{params[:name]}\" with address \"#{address}\"."
    redirect '/dashboard'
  end

  post '/set_timezone' do
    session[:timezone] = params[:name]
  end

  get '/signout' do
    require_login
    session[:account_email] = nil
    session[:timezone] = nil
    redirect '/'
  end

  def dashboard_if_signed_in
    redirect '/dashboard' if signed_in?
  end

  def require_login
    redirect '/' unless signed_in?
  end

  def signed_in?
    !session[:account_email].nil?
  end

  def bitcoin_rpc(meth, *args)
    $bitcoin.rpc(meth, *args)
  end

  def render(engine, data, options = {}, locals = {}, &block)
    options.merge!(pretty: self.class.development?) if engine == :slim && options[:pretty].nil?
    super engine, data, options, locals, &block
  end

  def create_account(email, password, temporary_password=false)
    account = Account.new email: email, password: password, temporary_password: temporary_password

    if account.valid?
      DB.transaction do
        account.save
        address = bitcoin_rpc 'getaccountaddress', email
        account.add_receive_address name: 'Default', bitcoin_address: address
      end
    end

    account
  end
end