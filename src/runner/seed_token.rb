# frozen_string_literal: true

# Ensures a limited-scope personal access token exists for runner bootstrap and
# writes it to the shared bootstrap volume. Runs inside the GitLab container via
# `gitlab-rails runner` (see post-reconfigure.sh). Based on GitLab's documented
# "Create a personal access token programmatically" procedure.
#
# Only the token recorded in /bootstrap/runner-pat-id is ever revoked, so tokens
# created by anyone else are never touched.

path = '/bootstrap/runner-pat'
id_path = '/bootstrap/runner-pat-id'
name = 'runner-bootstrap'
# create_runner: POST /user/runners; manage_runner: DELETE /runners/:id;
# read_api: GET /runners/:id (confirm ownership before deleting).
scopes = %w[create_runner manage_runner read_api]

def write_atomic(file, content)
  tmp = "#{file}.tmp"
  File.write(tmp, content)
  File.chmod(0o600, tmp)
  File.rename(tmp, file)
end

user = User.find_by_username('root')
abort('root user not found') if user.nil?

current = File.exist?(path) ? PersonalAccessToken.find_by_token(File.read(path).strip) : nil
if current&.active? && current.user_id == user.id &&
   current.scopes.map(&:to_s).sort == scopes.sort &&
   current.expires_at > 30.days.from_now.to_date
  puts 'runner-bootstrap token is valid'
  exit 0
end

old_id = File.exist?(id_path) ? File.read(id_path).strip.to_i : nil
old = old_id && user.personal_access_tokens.find_by(id: old_id, name: name)
old.revoke! if old&.active?

value = SecureRandom.alphanumeric(20)
token = user.personal_access_tokens.create!(scopes: scopes, name: name, expires_at: 365.days.from_now)
token.set_token(value)
token.save!

write_atomic(path, value)
write_atomic(id_path, token.id.to_s)
puts 'runner-bootstrap token created'
