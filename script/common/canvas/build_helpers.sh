#!/bin/bash
source script/common/utils/common.sh

function ensure_in_canvas_root_directory {
  if ! is_canvas_root; then
    echo "Please run from a Canvas root directory"
    exit 0
  fi
}

function is_canvas_root {
  CANVAS_IN_README=$(head -1 README.md 2>/dev/null | grep 'Canvas LMS')
  [[ "$CANVAS_IN_README" != "" ]] && is_git_dir
  return $?
}

function compile_assets {
  start_spinner "Compiling assets (css and js only, no docs or styleguide)..."
  _canvas_lms_track_with_log run_command bundle exec rake canvas:compile_assets_dev
  stop_spinner
}

function build_images {
  start_spinner 'Building docker images...'
  if [[ -n "$JENKINS" ]]; then
    _canvas_lms_track_with_log docker compose build --build-arg USER_ID=$(id -u)
  elif [[ "${OS:-}" == 'Linux' && -z "${CANVAS_SKIP_DOCKER_USERMOD:-}" ]]; then
    _canvas_lms_track_with_log docker compose build --pull --build-arg USER_ID=$(id -u)
  else
    _canvas_lms_track_with_log $DOCKER_COMMAND build --pull
  fi
  stop_spinner
}

# Define the list of lock files that bundle install needs to write to
MAIN_LOCK_FILES=(
  "Gemfile.lock"
  "Gemfile.rails72.plugins.lock" 
  "Gemfile.rails80.lock"
  "Gemfile.rails80.plugins.lock"
  "Gemfile.d/rubocop.rb.lock"
  "gems/tatl_tael/Gemfile.lock"
)

# Define directories that need to be created
REQUIRED_DIRS=(
  "gems/tatl_tael"
  "Gemfile.d"
)

function create_required_lock_files {
  message "Creating required lock files..."
  
  # Create directories
  for dir in "${REQUIRED_DIRS[@]}"; do
    docker-compose exec --user root web mkdir -p "$dir" 2>/dev/null || true
  done
  
  # Create lock files
  for file in "${MAIN_LOCK_FILES[@]}"; do
    docker-compose exec --user root web touch "$file" 2>/dev/null || true
  done
}

function fix_lock_file_permissions {
  message "Fixing lock file permissions..."
  confirm_command 'docker-compose exec --user root web find . -name "*.lock" -exec chmod 666 {} \;' || true
}

function clean_conflicting_lock_files {
  message "Cleaning conflicting lock files..."
  confirm_command "docker-compose exec --user root web rm -f ${MAIN_LOCK_FILES[*]}" || true
}

function check_gemfile_lock_permissions {
  message "Checking Gemfile.lock permissions..."
  
  # Create missing lock files as root first
  create_required_lock_files
  
  # Check for lock file conflicts and clean them if needed
  message "Checking for lock file conflicts..."
  if ! _canvas_lms_track_with_log run_command bundle check 2>/dev/null; then
    message \
"Lock files are out of sync or have conflicts. We need to clean them so bundle install
can regenerate them properly."
    
    clean_conflicting_lock_files
    create_required_lock_files
    fix_lock_file_permissions
  fi
  
  # Test if we can write to the lock files that bundle install needs
  if ! _canvas_lms_track_with_log run_command touch "${MAIN_LOCK_FILES[0]}" "${MAIN_LOCK_FILES[1]}" gems/activesupport-suspend_callbacks/Gemfile.lock 2>/dev/null; then
    message \
"The 'docker' user is not allowed to write to Gemfile.lock files. We need write
permissions so we can run bundle install."
    
    fix_lock_file_permissions
  fi
}

function check_yarn_permissions {
  message "Checking Yarn permissions..."
  
  # Test if we can write to Yarn directories
  if ! _canvas_lms_track_with_log run_command touch packages/canvas-media/test-write 2>/dev/null; then
    message \
"The 'docker' user is not allowed to write to Yarn directories. We need write
permissions so we can run yarn install."
    
    confirm_command 'docker-compose exec --user root web bash -c "mkdir -p packages/canvas-media/node_modules node_modules; touch yarn-error.log; chmod 666 yarn-error.log; chmod -R 777 packages/ node_modules/ 2>/dev/null || true"' || true
  fi
}

function check_webpack_permissions {
  message "Checking webpack compilation permissions..."
  
  # Test if we can write to webpack directories and files
  if ! _canvas_lms_track_with_log run_command touch ui/shared/bundles/extensions.ts 2>/dev/null; then
    message \
"The 'docker' user is not allowed to write to webpack directories. We need write
permissions so we can compile assets."
    
    confirm_command 'docker-compose exec --user root web bash -c "mkdir -p ui/shared/bundles translations; echo \"export default {};\" > ui/shared/bundles/extensions.ts; cp packages/translations/lib/en.json translations/en.json; chmod -R 777 ui/shared/bundles/ translations/ 2>/dev/null || true"' || true
  fi
}

function build_assets {
  message "Building assets..."
  check_gemfile_lock_permissions
  start_spinner "> Bundle install..."
  _canvas_lms_track_with_log run_command ./script/install_assets.sh -c bundle
  stop_spinner
  check_yarn_permissions
  start_spinner "> Yarn install...."
  _canvas_lms_track_with_log run_command ./script/install_assets.sh -c yarn
  stop_spinner
  check_webpack_permissions
  start_spinner "> Compile assets...."
  _canvas_lms_track_with_log run_command ./script/install_assets.sh -c compile
  stop_spinner
}

function database_exists {
  run_command bundle exec rails runner 'ActiveRecord::Base.connection' &> /dev/null
}

function create_db {
  if ! _canvas_lms_track_with_log run_command touch db/structure.sql; then
    message \
"The 'docker' user is not allowed to write to db/structure.sql. We need write
permissions so we can run migrations."
    touch db/structure.sql
    confirm_command 'chmod a+rw db/structure.sql' || true
  fi

  start_spinner "Checking for existing db..."
  _canvas_lms_track_with_log $DOCKER_COMMAND up -d web
  if database_exists; then
    stop_spinner
    message \
'An existing database was found.'
    if ! is_running_on_jenkins; then
      prompt "Do you want to drop and create new or migrate existing? [DROP/migrate] " dropped
    fi
    if [[ ${dropped:-migrate} == 'DROP' ]]; then
      message \
'!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
This script will destroy ALL EXISTING DATA if it continues
If you want to migrate the existing database, cancel now
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!'
      message 'About to run "bundle exec rake db:drop"'
      start_spinner "Deleting db....."
      _canvas_lms_track_with_log run_command bundle exec rake db:drop
      stop_spinner
    fi
  fi
  stop_spinner
  if [[ ${dropped:-DROP} == 'DROP' ]]; then
    start_spinner "Creating new database...."
    _canvas_lms_track_with_log run_command bundle exec rake db:create
    stop_spinner
  fi
  # Rails db:migrate only runs on development by default
  # https://discuss.rubyonrails.org/t/db-drop-create-migrate-behavior-with-rails-env-development/74435
  start_spinner "Migrating (Development env)...."
  _canvas_lms_track_with_log run_command bundle exec rake db:migrate RAILS_ENV=development
  stop_spinner
  start_spinner "Migrating (Test env)...."
  _canvas_lms_track_with_log run_command bundle exec rake db:migrate RAILS_ENV=test
  stop_spinner
  [[ ${dropped:-DROP} == 'migrate' ]] || _canvas_lms_track run_command_tty bundle exec rake db:initial_setup
}

function bundle_install {
  start_spinner "  Installing gems (bundle install) ..."
  _canvas_lms_track_with_log run_command bundle install
  stop_spinner
}

function rake_db_migrate_dev_and_test {
  start_spinner "Migrating development DB..."
  _canvas_lms_track_with_log run_command bundle exec rake db:migrate RAILS_ENV=development
  stop_spinner
  start_spinner "Migrating test DB..."
  _canvas_lms_track_with_log run_command bundle exec rake db:migrate RAILS_ENV=test
  stop_spinner
}

function install_node_packages {
  start_spinner "Installing Node packages..."
  _canvas_lms_track_with_log run_command bundle exec rake js:yarn_install
  stop_spinner
}

function copy_docker_config {
  message 'Copying Canvas docker configuration...'
  confirm_command 'cp docker-compose/config/*.yml config/' || true
}

function setup_docker_compose_override {
  message 'Setup override yaml and .env...'
  if [ -f "docker-compose.override.yml" ]; then
    message "docker-compose.override.yml already exists, skipping copy of default configuration!"
  else
    message "Copying default configuration from config/docker-compose.override.yml.example to docker-compose.override.yml"
    cp config/docker-compose.override.yml.example docker-compose.override.yml
  fi

  if [ -f ".env" ]; then
    prompt '.env file exists, would you like to reset it to default? [y/n]' confirm
    [[ ${confirm:-n} == 'y' ]] || return 0
  fi
  message "Setting up default .env configuration"
  echo -n "COMPOSE_FILE=docker-compose.yml:docker-compose.override.yml" > .env
}
