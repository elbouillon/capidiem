require 'yaml'

# Dirs that need to remain the same between deploys (shared dirs)
set :shared_children,   %w(log web/uploads)

# Files that need to remain the same between deploys
set :shared_files,      %w(config/databases.yml)

# Asset folders (that need to be timestamped)
set :asset_children,    %w(web/css web/images web/js)

# PHP binary to execute
set :php_bin,           "php"

# Diem environment on local
set :diem_env_local, "dev"

# Diem environment
set :diem_env,       "prod"

# Diem default ORM
set(:diem_orm)     { guess_diem_orm }

# Diem lib path
set(:diem_lib)     { guess_diem_lib }

def prompt_with_default(var, default, &block)
  set(var) do
    Capistrano::CLI.ui.ask("#{var} [#{default}] : ", &block)
  end
  set var, default if eval("#{var.to_s}.empty?")
end

def guess_diem_orm
  databases = YAML::load(IO.read('config/databases.yml'))

  if databases[diem_env_local]
    databases[diem_env_local].keys[0].to_s
  else
    databases['all'].keys[0].to_s
  end
end

def guess_diem_lib
  diem_version = capture("#{php_bin} #{latest_release}/diem -V")

  /\((.*)\)/.match(diem_version)[1]
end

def load_database_config(data, env)
  databases = YAML::load(data)

  if databases[env]
    db_param = databases[env][diem_orm]['param']
  else
    db_param = databases['all'][diem_orm]['param']
  end

  {
    'type'  => /(\w+)\:/.match(db_param['dsn'])[1],
    'user'  => db_param['username'],
    'pass'  => db_param['password'],
    'db'    => /dbname=([^;$]+)/.match(db_param['dsn'])[1]
  }
end

namespace :deploy do
  desc "Overwrite the start task because diem doesn't need it."
  task :start do ; end

  desc "Overwrite the restart task because diem doesn't need it."
  task :restart do ; end

  desc "Overwrite the stop task because diem doesn't need it."
  task :stop do ; end

  desc "Customize migrate task because diem doesn't need it."
  task :migrate do
    diem.orm.migrate
  end

  desc "Symlink static directories and static files that need to remain between deployments."
  task :share_childs do
    if shared_children
      shared_children.each do |link|
        run "mkdir -p #{shared_path}/#{link}"
        run "if [ -d #{release_path}/#{link} ] ; then rm -rf #{release_path}/#{link}; fi"
        run "ln -nfs #{shared_path}/#{link} #{release_path}/#{link}"
      end
    end
    if shared_files
      shared_files.each do |link|
        link_dir = File.dirname("#{shared_path}/#{link}")
        run "mkdir -p #{link_dir}"
        run "touch #{shared_path}/#{link}"
        run "ln -nfs #{shared_path}/#{link} #{release_path}/#{link}"
      end
    end
  end

  desc "Customize the finalize_update task to work with diem."
  task :finalize_update, :except => { :no_release => true } do
    run "chmod -R g+w #{latest_release}" if fetch(:group_writable, true)
    run "mkdir -p #{latest_release}/cache"

    # Share common files & folders
    share_childs

    if fetch(:normalize_asset_timestamps, true)
      stamp = Time.now.utc.strftime("%Y%m%d%H%M.%S")
      asset_paths = asset_children.map { |p| "#{latest_release}/#{p}" }.join(" ")
      run "find #{asset_paths} -exec touch -t #{stamp} {} ';'; true", :env => { "TZ" => "UTC" }
    end
  end

  desc "Need to overwrite the deploy:cold task so it doesn't try to run the migrations."
  task :cold do
    update
    diem.orm.build_db_and_load
    start
  end

  desc "Deploy the application and run the test suite."
  task :testall do
    update_code
    symlink
    diem.orm.build_db_and_load
    diem.tests.all
  end
end

namespace :diem do
  desc "Runs custom diem task"
  task :default do
    prompt_with_default(:task_arguments, "cache:clear")

    stream "#{php_bin} #{latest_release}/diem #{task_arguments}"
  end

  desc "Downloads & runs check_configuration.php on remote"
  task :check_configuration do
    prompt_with_default(:version, "1.4")

    run "wget  http://sf-to.org/#{version}/check.php -O /tmp/check_configuration.php"
    stream "#{php_bin} /tmp/check_configuration.php"
    run "rm /tmp/check_configuration.php"
  end

  desc "Clears the cache"
  task :cc do
    run "#{php_bin} #{latest_release}/diem cache:clear"
  end

  namespace :configure do
    desc "Configure database DSN"
    task :database do
      prompt_with_default(:dsn,         "mysql:host=localhost;dbname=#{application}")
      prompt_with_default(:db_username, "root")
      db_password = Capistrano::CLI.password_prompt("db_password : ")

      # surpress debug log output to hide the password
      current_logger_level = self.logger.level
      if current_logger_level >= Capistrano::Logger::DEBUG
        logger.debug %(executing "#{php_bin} #{latest_release}/diem configure:database '#{dsn}' '#{db_username}' ***")
        self.logger.level = Capistrano::Logger::INFO 
      end

      run "#{php_bin} #{latest_release}/diem configure:database '#{dsn}' '#{db_username}' '#{db_password}'"

      # restore logger level
      self.logger.level = current_logger_level
    end
  end

  namespace :project do
    desc "Disables an application in a given environment"
    task :disable do
      run "#{php_bin} #{latest_release}/diem project:disable #{diem_env}"
    end

    desc "Enables an application in a given environment"
    task :enable do
      run "#{php_bin} #{latest_release}/diem project:enable #{diem_env}"
    end

    desc "Fixes diem directory permissions"
    task :permissions do
      run "#{php_bin} #{latest_release}/diem project:permissions"
    end

    desc "Optimizes a project for better performance"
    task :optimize do
      prompt_with_default(:application, "frontend")

      run "#{php_bin} #{latest_release}/diem project:optimize #{application}"
    end

    desc "Clears all non production environment controllers"
    task :clear_controllers do
      run "#{php_bin} #{latest_release}/diem project:clear-controllers"
    end

    desc "Sends emails stored in a queue"
    task :send_emails do
      prompt_with_default(:message_limit, 10)
      prompt_with_default(:time_limit,    10)

      stream "#{php_bin} #{latest_release}/diem project:send-emails --message-limit=#{message_limit} --time-limit=#{time_limit} --env=#{diem_env}"
    end
  end

  namespace :plugin do
    desc "Publishes web assets for all plugins"
    task :publish_assets do
      run "#{php_bin} #{latest_release}/diem plugin:publish-assets"
    end
  end

  namespace :log do
    desc "Clears log files"
    task :clear do
      run "#{php_bin} #{latest_release}/diem log:clear"
    end

    desc "Rotates an application's log files"
    task :rotate do
      prompt_with_default(:application, "frontend")

      run "#{php_bin} #{latest_release}/diem log:rotate #{application} #{diem_env}"
    end
  end

  namespace :tests do
    desc "Launches all tests"
    task :all do
      run "#{php_bin} #{latest_release}/diem test:all"
    end

    desc "Launches functional tests"
    task :functional do
      prompt_with_default(:application, "frontend")

      run "#{php_bin} #{latest_release}/diem test:functional #{application}"
    end

    desc "Launches unit tests"
    task :unit do
      run "#{php_bin} #{latest_release}/diem test:unit"
    end
  end

  namespace :orm do
    desc "Ensure diem ORM is properly configured"
    task :setup do
      find_and_execute_task("diem:#{diem_orm}:setup")
    end
  
    desc "Migrates database to current version"
    task :migrate do
      find_and_execute_task("diem:#{diem_orm}:migrate")
    end

    desc "Generate model lib form and filters classes based on your schema"
    task :build_classes do
      find_and_execute_task("diem:#{diem_orm}:build_classes")
    end

    desc "Generate code & database based on your schema"
    task :build_all do
      find_and_execute_task("diem:#{diem_orm}:build_all")
    end

    desc "Generate code & database based on your schema & load fixtures"
    task :build_all_and_load do
      find_and_execute_task("diem:#{diem_orm}:build_all_and_load")
    end

    desc "Generate sql & database based on your schema"
    task :build_db do
      find_and_execute_task("diem:#{diem_orm}:build_db")
    end

    desc "Generate sql & database based on your schema & load fixtures"
    task :build_db_and_load do
      find_and_execute_task("diem:#{diem_orm}:build_db_and_load")
    end
  end

  namespace :doctrine do
    desc "Ensure Doctrine is correctly configured"
    task :setup do 
      conf_files_exists = capture("if test -s #{shared_path}/config/databases.yml ; then echo 'exists' ; fi").strip
      if (!conf_files_exists.eql?("exists"))
        diem.configure.database
      end
    end

    desc "Execute a DQL query and view the results"
    task :dql do
      prompt_with_default(:query, "")

      stream "#{php_bin} #{latest_release}/diem doctrine:dql #{query} --env=#{diem_env}"
    end

    desc "Dumps data to the fixtures directory"
    task :data_dump do
      run "#{php_bin} #{latest_release}/diem doctrine:data-dump --env=#{diem_env}"
    end

    desc "Loads YAML fixture data"
    task :data_load do
      run "#{php_bin} #{latest_release}/diem doctrine:data-load --env=#{diem_env}"
    end

    desc "Loads YAML fixture data without remove"
    task :data_load_append do
      run "#{php_bin} #{latest_release}/diem doctrine:data-load --append --env=#{diem_env}"
    end

    desc "Migrates database to current version"
    task :migrate do
      run "#{php_bin} #{latest_release}/diem doctrine:migrate --env=#{diem_env}"
    end

    desc "Generate model lib form and filters classes based on your schema"
    task :build_classes do
      run "#{php_bin} #{latest_release}/diem doctrine:build --all-classes --env=#{diem_env}"
    end

    desc "Generate code & database based on your schema"
    task :build_all do
      if Capistrano::CLI.ui.agree("Do you really want to rebuild #{diem_env}'s database? (y/N)")
        run "#{php_bin} #{latest_release}/diem doctrine:build --all --no-confirmation --env=#{diem_env}"
      end
    end

    desc "Generate code & database based on your schema & load fixtures"
    task :build_all_and_load do
      if Capistrano::CLI.ui.agree("Do you really want to rebuild #{diem_env}'s database and load #{diem_env}'s fixtures? (y/N)")
        run "#{php_bin} #{latest_release}/diem doctrine:build --all --and-load --no-confirmation --env=#{diem_env}"
      end
    end

    desc "Generate sql & database based on your schema"
    task :build_db do
      if Capistrano::CLI.ui.agree("Do you really want to rebuild #{diem_env}'s database? (y/N)")
        run "#{php_bin} #{latest_release}/diem doctrine:build --sql --db --no-confirmation --env=#{diem_env}"
      end
    end

    desc "Generate sql & database based on your schema & load fixtures"
    task :build_db_and_load do
      if Capistrano::CLI.ui.agree("Do you really want to rebuild #{diem_env}'s database and load #{diem_env}'s fixtures? (y/N)")
        run "#{php_bin} #{latest_release}/diem doctrine:build --sql --db --and-load --no-confirmation --env=#{diem_env}"
      end
    end
  end

  namespace :propel do
    desc "Ensure Propel is correctly configured"
    task :setup do
      conf_files_exists = capture("if test -s #{shared_path}/config/propel.ini -a -s #{shared_path}/config/databases.yml ; then echo 'exists' ; fi").strip

      # share childs again (for propel.ini file)
      shared_files << "config/propel.ini"
      deploy.share_childs

      if (!conf_files_exists.eql?("exists"))
        run "cp #{diem_lib}/plugins/sfPropelPlugin/config/skeleton/config/propel.ini #{shared_path}/config/propel.ini"
        diem.configure.database
      end
    end

    desc "Migrates database to current version"
    task :migrate do
      puts "propel doesn't have built-in migration for now"
    end

    desc "Generate model lib form and filters classes based on your schema"
    task :build_classes do
      run "php #{latest_release}/diem propel:build --all-classes --env=#{diem_env}"
    end

    desc "Generate code & database based on your schema"
    task :build_all do
      if Capistrano::CLI.ui.agree("Do you really want to rebuild #{diem_env}'s database? (y/N)")
        run "#{php_bin} #{latest_release}/diem propel:build --sql --db --no-confirmation --env=#{diem_env}"
      end
    end

    desc "Generate code & database based on your schema & load fixtures"
    task :build_all_and_load do
      if Capistrano::CLI.ui.agree("Do you really want to rebuild #{diem_env}'s database and load #{diem_env}'s fixtures? (y/N)")
        run "#{php_bin} #{latest_release}/diem propel:build --sql --db --and-load --no-confirmation --env=#{diem_env}"
      end
    end

    desc "Generate sql & database based on your schema"
    task :build_db do
      if Capistrano::CLI.ui.agree("Do you really want to rebuild #{diem_env}'s database? (y/N)")
        run "#{php_bin} #{latest_release}/diem propel:build --sql --db --no-confirmation --env=#{diem_env}"
      end
    end

    desc "Generate sql & database based on your schema & load fixtures"
    task :build_db_and_load do
      if Capistrano::CLI.ui.agree("Do you really want to rebuild #{diem_env}'s database and load #{diem_env}'s fixtures? (y/N)")
        run "#{php_bin} #{latest_release}/diem propel:build --sql --db --and-load --no-confirmation --env=#{diem_env}"
      end
    end
  end
end

namespace :database do
  namespace :dump do
    desc "Dump remote database"
    task :remote do
      filename  = "#{application}.remote_dump.#{Time.now.to_i}.sql.bz2"
      file      = "/tmp/#{filename}"
      sqlfile   = "#{application}_dump.sql"
      config    = ""

      run "cat #{shared_path}/config/databases.yml" do |ch, st, data|
        config = load_database_config data, diem_env
      end

      case config['type']
      when 'mysql'
        run "mysqldump -u#{config['user']} --password='#{config['pass']}' #{config['db']} | bzip2 -c > #{file}" do |ch, stream, data|
          puts data
        end
      when 'pgsql'
        run "pg_dump -U #{config['user']} --password='#{config['pass']}' #{config['db']} | bzip2 -c > #{file}" do |ch, stream, data|
          puts data
        end
      end

      `mkdir -p backups`
      get file, "backups/#{filename}"
      `cd backups && ln -nfs #{filename} #{application}.remote_dump.latest.sql.bz2`
      run "rm #{file}"
    end

    desc "Dump local database"
    task :local do
      filename  = "#{application}.local_dump.#{Time.now.to_i}.sql.bz2"
      file      = "backups/#{filename}"
      config    = load_database_config IO.read('config/databases.yml'), diem_env_local
      sqlfile   = "#{application}_dump.sql"

      `mkdir -p backups`
      case config['type']
      when 'mysql'
        `mysqldump -u#{config['user']} --password='#{config['pass']}' #{config['db']} | bzip2 -c > #{file}`
      when 'pgsql'
        `pg_dump -U #{config['user']} --password='#{config['pass']}' #{config['db']} | bzip2 -c > #{file}`
      end

      `cd backups && ln -nfs #{filename} #{application}.local_dump.latest.sql.bz2`
    end
  end

  namespace :move do
    desc "Dump remote database, download it to local & populate here"
    task :to_local do
      filename  = "#{application}.remote_dump.latest.sql.bz2"
      config    = load_database_config IO.read('config/databases.yml'), diem_env_local
      sqlfile   = "#{application}_dump.sql"

      database.dump.remote

      `bunzip2 -kc backups/#{filename} > backups/#{sqlfile}`
      case config['type']
      when 'mysql'
        `mysql -u#{config['user']} --password='#{config['pass']}' #{config['db']} < backups/#{sqlfile}`
      when 'pgsql'
        `psql -U #{config['user']} --password='#{config['pass']}' #{config['db']} < backups/#{sqlfile}`
      end
      `rm backups/#{sqlfile}`
    end

    desc "Dump local database, load it to remote & populate there"
    task :to_remote do
      filename  = "#{application}.local_dump.latest.sql.bz2"
      file      = "backups/#{filename}"
      sqlfile   = "#{application}_dump.sql"
      config    = ""

      database.dump.local

      upload(file, "/tmp/#{filename}", :via => :scp)
      run "bunzip2 -kc /tmp/#{filename} > /tmp/#{sqlfile}"

      run "cat #{shared_path}/config/databases.yml" do |ch, st, data|
        config = load_database_config data, diem_env
      end

      case config['type']
      when 'mysql'
        run "mysql -u#{config['user']} --password='#{config['pass']}' #{config['db']} < /tmp/#{sqlfile}" do |ch, stream, data|
          puts data
        end
      when 'pgsql'
        run "psql -U #{config['user']} --password='#{config['pass']}' #{config['db']} < /tmp/#{sqlfile}" do |ch, stream, data|
          puts data
        end
      end

      run "rm /tmp/#{filename}"
      run "rm /tmp/#{sqlfile}"
    end
  end
end

namespace :shared do
  namespace :databases do
    desc "Download config/databases.yml from remote server"
    task :to_local do
      download("#{shared_path}/config/databases.yml", "config/databases.yml", :via => :scp)
    end

    desc "Upload config/databases.yml to remote server"
    task :to_remote do
      upload("config/databases.yml", "#{shared_path}/config/databases.yml", :via => :scp)
    end
  end

  namespace :log do
    desc "Download all logs from remote folder to local one"
    task :to_local do
      download("#{shared_path}/log", "./", :via => :scp, :recursive => true)
    end

    desc "Upload all logs from local folder to remote one"
    task :to_remote do
      upload("log", "#{shared_path}/", :via => :scp, :recursive => true)
    end
  end

  namespace :uploads do
    desc "Download all files from remote web/uploads folder to local one"
    task :to_local do
      download("#{shared_path}/web/uploads", "web", :via => :scp, :recursive => true)
    end

    desc "Upload all files from local web/uploads folder to remote one"
    task :to_remote do
      upload("web/uploads", "#{shared_path}/web", :via => :scp, :recursive => true)
    end
  end
end

# After finalizing update:
after "deploy:finalize_update" do
  diem.orm.setup                       # 0. Ensure that ORM is configured
  diem.orm.build_classes               # 1. (Re)build the model
  diem.cc                              # 2. Clear cache
  diem.plugin.publish_assets           # 3. Publish plugin assets
  diem.project.permissions             # 4. Fix project permissions
  if diem_env.eql?("prod")
    diem.project.clear_controllers     # 5. Clear controllers in production environment
  end
end
