# Ensures a limited-scope personal access token exists for runner bootstrap and
# writes it to the shared bootstrap volume. Runs inside the GitLab container via
# `gitlab-rails runner` (see post-reconfigure.sh). Based on GitLab's documented
# "Create a personal access token programmatically" procedure.

path = '/bootstrap/runner-pat'
name = 'runner-bootstrap'
# create_runner: POST /user/runners; manage_runner: DELETE /runners/:id;
# read_api: GET /runners/all (find stale runners).
scopes = %w[create_runner manage_runner read_api]

user = User.find_by_username('root')
abort('root user not found') if user.nil?

current = File.exist?(path) ? PersonalAccessToken.find_by_token(File.read(path).strip) : nil
if current&.active? && current.user_id == user.id &&
   current.scopes.map(&:to_s).sort == scopes.sort &&
   current.expires_at > 30.days.from_now.to_date
  puts 'runner-bootstrap token is valid'
  exit 0
end

user.personal_access_tokens.active.where(name: name).find_each(&:revoke!)

value = SecureRandom.alphanumeric(20)
token = user.personal_access_tokens.create!(scopes: scopes, name: name, expires_at: 365.days.from_now)
token.set_token(value)
token.save!

tmp = "#{path}.tmp"
File.write(tmp, value)
File.chmod(0o600, tmp)
File.rename(tmp, path)
puts 'runner-bootstrap token created'
