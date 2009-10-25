desc "Open this repo's master branch in a web browser."
command :home do |user|
  if helper.project
    helper.open helper.homepage_for(user || helper.owner, 'master')
  end
end

desc "Automatically set configuration info, or pass args to specify."
usage "github config [my_username] [my_repo_name] [my_token]"
command :config do |user, repo, token|
  user ||= ENV['USER']
  repo ||= File.basename(FileUtils.pwd)
  git "config --global github.user #{user}"
  git "config github.repo #{repo}"
  git "config --global github.token #{token}" unless token == ''
  puts "Configured with github.user #{user}, github.repo #{repo}" +
       (token ? ", github.token #{token}" : "")
end

desc "Open this repo in a web browser."
usage "github browse [user] [branch]"
command :browse do |user, branch|
  if helper.project
    # if one arg given, treat it as a branch name
    # unless it maches user/branch, then split it
    # if two args given, treat as user branch
    # if no args given, use defaults
    user, branch = user.split("/", 2) if branch.nil? unless user.nil?
    branch = user and user = nil if branch.nil?
    user ||= helper.branch_user
    branch ||= helper.branch_name
    helper.open helper.homepage_for(user, branch)
  end
end

desc 'Open the given user/project in a web browser'
usage 'github open [user/project]'
command :open do |arg|
  helper.open "http://github.com/#{arg}"
end

desc "Info about this project."
command :info do
  puts "== Info for #{helper.project}"
  puts "You are #{helper.owner}"
  puts "Currently tracking:"
  helper.tracking.sort { |a,b| a == helper.origin ? -1 : b == helper.origin ? 1 : a.to_s <=> b.to_s }.each do |(name,user_or_url)|
    puts " - #{user_or_url} (as #{name})"
  end
end

desc "Track another user's repository."
usage "github track remote [user]"
usage "github track remote [user/repo]"
usage "github track [user]"
usage "github track [user/repo]"
flags :private => 'Use git@github.com: instead of git://github.com/.'
flags :ssh => 'Equivalent to --private'
flags :mainline => 'Mark this user as mainline. Used for github review.'
command :track do |remote, user|
  # track remote user
  # track remote user/repo
  # track user
  # track user/repo
  user, remote = remote, nil if user.nil?
  die "Specify a user to track" if user.nil?
  user, repo = user.split("/", 2)

  remote ||= user
  if helper.tracking?(user)
    if options[:mainline]
      puts "Setting mainline repo to #{remote}"
      helper.mainline_repo(remote)
      return;
    end
    die "Already tracking #{user}"
  end
  repo = @helper.project if repo.nil?
  repo.chomp!(".git")

  if options[:private] || options[:ssh]
    git "remote add #{remote} #{helper.private_url_for_user_and_repo(user, repo)}"
  else
    git "remote add #{remote} #{helper.public_url_for_user_and_repo(user, repo)}"
  end
  if options[:mainline]
      helper.mainline_repo(remote)
  end
end

desc "Fetch all refs from a user"
command :fetch_all do |user|
  GitHub.invoke(:track, user) unless helper.tracking?(user)
  puts git("fetch #{user}")
end

desc "Get/set the mainline repo"
command :mainline do |remote|
    if remote.nil?
        puts helper.mainline_repo
    else
        puts "Setting new mainline as #{remote}"
        helper.mainline_repo(remote)
    end
end

desc "Review another users branch before merging"
command :review do |user, branch|
  original_branch = helper.current_branch
  user, branch = branch, nil if user.nil?
  die "Specify a user to review" if user.nil?
  user, branch = user.split("/", 2) if branch.nil?
  GitHub.invoke(:fetch_all, user)

  mainline = helper.mainline_repo
  GitHub.invoke(:fetch_all, mainline);

  if git_ret("checkout -b review##{user}/#{branch} #{mainline}/master") != 0
      die "Couldn't checkout #{mainline}/master to review against."
  end

  merge_message = git("merge #{user}/#{branch}")
  if merge_message == "Already up-to-date."
    puts "Branch #{user}/#{branch} is already merged to #{mainline}/master."
    puts "Nothing to do."
  elsif merge_message =~ /^fatal: /
    puts merge_message
    puts "Nothing I can do."
  else
    return
  end
 
  # Cleanup if we're still here
  git "checkout #{original_branch}"
  git "branch -D review##{user}/#{branch}"
end

desc "Difference between mainline/master and local"
command :'mainline-diff' do
    mainline = helper.mainline_repo
    git_exec("diff #{mainline}/master")
end

desc "Pass review by merging into origin/master"
command :'review-pass' do
  branch = helper.current_branch

  branch =~ /^review#/ or
    die "Must be in a review branch"
  helper.branch_dirty? and
    die "Cannot pass review, your current branch has uncommited changes"

  mainline = helper.mainline_repo

  # Should be ready.
  puts "Pushing to #{mainline}"
  puts git "push #{mainline} HEAD:master"
  puts git "checkout master"
  puts "Merged #{branch} to #{mainline}/master"
end

desc "Fail review by sending message"
command :'review-fail' do
  branch = helper.current_branch

  branch =~ /^review#/ or
    die "Must be in a review branch"
  orig_branch = branch.sub(/^review#/, '')
  user = branch.scan(/^review#(.*?)\//)

  message_file = (git "rev-parse --git-dir") + "/GitHubFailPullRequestMessage"

  File.open(message_file, 'w') do |aFile|
    aFile.puts "# To: #{user}"
    aFile.puts ""
    aFile.puts "# Please enter the reason you are rejecting this pull-request " +
               " Lines starting"
    aFile.puts "# with '#' will be ignored, and an empty message aborts "  +
               "the commit."
    aFile.puts "#"
    aFile.puts "#"
    aFile.puts "# --------"
    aFile.puts "#"

    gitcommits = git "log -u origin/master..#{branch}"
    gitcommits.split(/\n/).each { |line|
        aFile.puts "# #{line}"
    }
  end

  system "#{editor} '#{message_file}'"
  message_content = ""
  File.open(message_file, 'r') do |aFile|
    aFile.each { |line|
      next if line =~ /^#/
      message_content += line
    }
  end

# Only comments or only our initial blank line are consitered abort-worthy
  if not message_content.empty? and message_content != "\n"
    sh 'curl', "-Flogin=#{github_user}", "-Ftoken=#{github_token}",
      "-Fmessage[body]=#{message_content}", "-Fmessage[to]=#{user}",
      "-Fmessage[subject]=Reject pull-request for #{orig_branch}",
      "http://github.com/inbox"
    puts "Sent github message to #{user}"
    File.unlink(message_file)
  else
    puts "Aborted review-fail due to empty message."
    return;
  end

  if git_ret('diff', '--quiet', orig_branch) != 0
    puts "Preserving #{branch} as it has local changes. You can delete with: "
    puts "   git branch -D #{branch}"
  else
      git "checkout master"
      git_exec "branch -D #{branch}"
  end
  
end

desc "Cancel a review"
command :'review-cancel' do
  branch = helper.current_branch

  branch =~ /^review#/ or
    die "Must be in a review branch"
  git_ret("checkout master")
  git_ret("branch -D #{branch}")
end

desc "Fetch from a remote to a local branch."
command :fetch do |user, branch|
  die "Specify a user to pull from" if user.nil?
  user, branch = user.split("/", 2) if branch.nil?
  branch ||= 'master'
  GitHub.invoke(:track, user) unless helper.tracking?(user)

  die "Unknown branch (#{branch}) specified" unless helper.remote_branch?(user, branch)
  die "Unable to switch branches, your current branch has uncommitted changes" if helper.branch_dirty?

  puts "Fetching #{user}/#{branch}"
  git "fetch #{user} #{branch}:refs/remotes/#{user}/#{branch}"
  git "update-ref refs/heads/#{user}/#{branch} refs/remotes/#{user}/#{branch}"
  git_exec "checkout #{user}/#{branch}"
end

desc "Pull from a remote."
usage "github pull [user] [branch]"
flags :merge => "Automatically merge remote's changes into your master."
command :pull do |user, branch|
  die "Specify a user to pull from" if user.nil?
  user, branch = user.split("/", 2) if branch.nil?

  if !helper.network_members(user, {}).include?(user)
    git_exec "#{helper.argv.join(' ')}".strip
    return
  end

  branch ||= 'master'
  GitHub.invoke(:track, user) unless helper.tracking?(user)

  die "Unable to switch branches, your current branch has uncommitted changes" if helper.branch_dirty?

  if options[:merge]
    git_exec "pull #{user} #{branch}"
  else
    puts "Switching to #{user}-#{branch}"
    git "fetch #{user}"
    git_exec "checkout -b #{user}/#{branch} #{user}/#{branch}"
  end
end

desc "Clone a repo. Uses ssh if current user is "
usage "github clone [user] [repo] [dir]"
flags :ssh => "Clone using the git@github.com style url."
flags :search => "Search for [user|repo] and clone selected repository"
command :clone do |user, repo, dir|
  die "Specify a user to pull from" if user.nil?
  if options[:search]
    query = [user, repo, dir].compact.join(" ")
    data = JSON.parse(open("http://github.com/api/v1/json/search/#{URI.escape query}").read)
    if (repos = data['repositories']) && !repos.nil? && repos.length > 0
      repo_list = repos.map do |r|
        { "name" => "#{r['username']}/#{r['name']}", "description" => r['description'] }
      end
      formatted_list = helper.format_list(repo_list).split("\n")
      if user_repo = GitHub::UI.display_select_list(formatted_list)
        user, repo = user_repo.strip.split('/', 2)
      end
    end
    die "Perhaps try another search" unless user && repo
  end

  if user.include?('/') && !user.include?('@') && !user.include?(':')
    die "Expected user/repo dir, given extra argument" if dir
    (user, repo), dir = [user.split('/', 2), repo]
  end

  if repo
    if options[:ssh] || current_user?(user)
      git_exec "clone git@github.com:#{user}/#{repo}.git" + (dir ? " #{dir}" : "")
    else
      git_exec "clone git://github.com/#{user}/#{repo}.git" + (dir ? " #{dir}" : "")
    end
  else
    git_exec "#{helper.argv.join(' ')}".strip
  end
end

desc "Generate a github pull-request"
usage "github pull-request [user]"
command :'pull-request' do |*users|
  if helper.project
    die "Specify at least one user to send the pull request" if users.length == 0
    branch = helper.current_branch
    project = helper.project
    if helper.branch_dirty_from_remote?
      die "Current branch differs from remote branch of the same name. \n" +
          "Perhaps you wish to \"git push\" or \"github push-branch\" first."
    end
    for user in (users)
      GitHub.invoke(:track, user) unless helper.tracking?(user)
    end

# Open the editor and have them enter their pull-request message
    message_file = (git "rev-parse --git-dir") + "/GitHubPullRequestMessage"

    File.open(message_file, 'w') do |aFile|
        aFile.puts "# To: " + users.join(', ')
        aFile.puts ""
        aFile.puts "If using the github-gem, review with: "
        aFile.puts "   github review #{github_user}/#{branch}"
        aFile.puts "# Please enter the pull-request message for your changes." +
                   " Lines starting"
        aFile.puts "# with '#' will be ignored, and an empty message aborts "  +
                   "the commit."
        aFile.puts "#"
        aFile.puts "# --------"
        aFile.puts "#"

        gitcommits = git "log -u origin/master..#{branch}"
        gitcommits.split(/\n/).each { |line|
            aFile.puts "# #{line}"
        }

    end

    system "#{editor} '#{message_file}'"
    message_content = ""
    File.open(message_file, 'r') do |aFile|
      aFile.each { |line|
          next if line =~ /^#/
          message_content += line
      }
    end

# Only comments or only our initial blank line are consitered abort-worthy
    if not message_content.empty? and message_content != "\n"
      args = [ 'curl', "-Flogin=#{github_user}", "-Ftoken=#{github_token}",
               "-Fmessage[body]=#{message_content}" ]

      for user in (users)
        args.push("-Fmessage[to][]=#{user}")
      end

      args.push(
        "http://github.com/#{github_user}/#{project}/pull_request/#{branch}"
        )
      sh(*args)
      File.unlink(message_file)
    else
      puts "Aborted pull-request due to empty message."
    end

  end
end

desc "Generate the text for a pull request."
usage "github pull-request-text [user] [branch]"
command :'pull-request-text' do |user, branch|
  if helper.project
    die "Specify a user for the pull request" if user.nil?
    user, branch = user.split('/', 2) if branch.nil?
    branch ||= 'master'
    GitHub.invoke(:track, user) unless helper.tracking?(user)

    git_exec "request-pull #{user}/#{branch} #{helper.origin}"
  end
end

desc "Create a new, empty GitHub repository"
usage "github create [repo]"
flags :markdown => 'Create README.markdown'
flags :mdown => 'Create README.mdown'
flags :textile => 'Create README.textile'
flags :rdoc => 'Create README.rdoc'
flags :rst => 'Create README.rst'
flags :private => 'Create private repository'
command :create do |repo|
  sh "curl -F 'repository[name]=#{repo}' -F 'repository[public]=#{!options[:private]}' -F 'login=#{github_user}' -F 'token=#{github_token}' http://github.com/repositories"
  mkdir repo
  cd repo
  git "init"
  extension = options.keys.first
  touch extension ? "README.#{extension}" : "README"
  git "add *"
  git "commit -m 'First commit!'"
  git "remote add origin git@github.com:#{github_user}/#{repo}.git"
  git_exec "push origin master"
end

desc "Forks a GitHub repository"
usage "github fork"
usage "github fork [user]/[repo]"
command :fork do |user, repo|
  if repo.nil?
    if user
      user, repo = user.split('/')
    else
      unless helper.remotes.empty?
        is_repo = true
        user = helper.owner
        repo = helper.project
      else
        die "Specify a user/project to fork, or run from within a repo"
      end
    end
  end

  sh "curl -F 'login=#{github_user}' -F 'token=#{github_token}' http://github.com/#{user}/#{repo}/fork"

  url = "git@github.com:#{github_user}/#{repo}.git"
  if is_repo
    git "config remote.origin.url #{url}"
    puts "#{user}/#{repo} forked"
  else
    puts "Giving GitHub a moment to create the fork..."
    sleep 3
    git_exec "clone #{url}"
  end
end

desc "Create a new GitHub repository from the current local repository"
flags :private => 'Create private repository'
command :'create-from-local' do
  cwd = sh "pwd"
  repo = File.basename(cwd)
  is_repo = !git("status").match(/fatal/)
  raise "Not a git repository. Use gh create instead" unless is_repo
  sh  "curl -F 'repository[name]=#{repo}' -F 'repository[public]=#{!options[:private].inspect} -F 'login=#{github_user}' -F 'token=#{github_token}' http://github.com/repositories"
  git "remote add origin git@github.com:#{github_user}/#{repo}.git"
  git_exec "push origin master"
end

desc "Push current local branch to new remote branch"
command :'push-branch' do
  branch = helper.current_branch
  if helper.remote_branch?("origin", branch)
    die "Remote branch #{branch} already exists" 
  end
  git "config branch.#{branch}.remote origin"
  git "config branch.#{branch}.merge refs/head/#{branch}"
  git_exec "push origin #{branch}"
end

desc "Diff between local branch and github's version of the same branch"
command :diff do
  branch = helper.current_branch
  git_exec "diff origin/#{branch}"
end

desc "Rebase local commits not yet pushed to github branch"
command :rebase do
  branch = helper.current_branch
  git_exec "rebase -i origin/#{branch}"
end

desc "Search GitHub for the given repository name."
usage "github search [query]"
command :search do |query|
  die "Usage: github search [query]" if query.nil?
  data = JSON.parse(open("http://github.com/api/v1/json/search/#{URI.escape query}").read)
  if (repos = data['repositories']) && !repos.nil? && repos.length > 0
    puts repos.map { |r| "#{r['username']}/#{r['name']}"}.sort.uniq
  else
    puts "No results found"
  end
end
desc "Uploads a file to GitHub's non-repo storage"
usage "github upload [filename]"
usage "github upload [filename] [user]/[repo]"
command :upload do |filename, user, repo|
  die "Specify a file to upload" if filename.nil?
  if repo.nil?
    if user
      user, repo = user.split('/')
    else
      user = helper.owner
      repo = helper.project
    end
  end
  die "Cannot determine GitHub repo" if user.nil? || repo.nil?

  die "Target file does not exist" unless File.size?(filename)
  file = File.new(filename)
  mime_type = MIME::Types.type_for(filename)[0] || MIME::Types["application/octet-stream"][0]

  res = helper.http_get "https://github.com/#{user}/#{repo}/downloads?login=#{github_user}&token=#{github_token}"
  is_public = res.body =~ /You are being <a href="http:\/\/github.com/
  schema = is_public ? "http" : "https"
  res = helper.http_get "#{schema}://github.com/#{user}/#{repo}/downloads?login=#{github_user}&token=#{github_token}" if is_public
  die "File has already been uploaded" if res.body =~ /<td><a href=".+?\/downloads\/#{user}\/#{repo}\/#{filename}.*">#{filename}<\/a><\/td>/

  res = helper.http_post("#{schema}://github.com/#{user}/#{repo}/downloads", {
    :file_size => File.size(filename),
    :content_type => mime_type.simplified,
    :file_name => filename,
    :description => '',
    :login => github_user,
    :token => github_token,
  })
  die "Repo not found" if res.class == Net::HTTPNotFound
  data = XmlSimple.xml_in(res.body)
  die "Unable to authorize upload" if data["signature"].nil?

  res = helper.http_post_multipart("http://github.s3.amazonaws.com/", {
    :key => "#{data["prefix"].first}#{filename}",
    :Filename => filename,
    :policy => data["policy"].first,
    :AWSAccessKeyId => data["accesskeyid"].first,
    :signature => data["signature"].first,
    :acl => data["acl"].first,
    :file => file,
    :success_action_status => 201
  })
  die "File upload failed" unless res.class == Net::HTTPCreated
  puts "File uploaded successfully"
end
