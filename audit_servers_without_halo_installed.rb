# Copyright (c) 2013, Eric Hoffmann <ehoffmann@cloudpassage.com>
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
#   * Redistributions of source code must retain the above copyright
#     notice, this list of conditions and the following disclaimer.
#   * Redistributions in binary form must reproduce the above copyright
#     notice, this list of conditions and the following disclaimer in the
#     documentation and/or other materials provided with the distribution.
#   * Neither the name of the CloudPassage, Inc. nor the
#     names of its contributors may be used to endorse or promote products
#     derived from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL CLOUDPASSAGE, INC. BE LIABLE FOR ANY DIRECT,
# INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
# BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
# DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED ANDON ANY THEORY OF
# LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
# NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
# EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
require 'fog'
require 'json'
require 'rest_client'
require 'base64'

# create a connection to the provisioned Provider
class FogCalls
  def initialize(provider, credential_path, region)
    if provider.downcase == 'AWS'.downcase
      Fog.credentials_path = "#{credential_path}"
      @conn = Fog::Compute.new(provider: 'AWS', region: region)

    elsif provider.downcase == 'Rackspace'.downcase
      Fog.credentials_path = "#{credential_path}"
      @conn = Fog::Compute.new(provider: 'Rackspace')

    else
      # add additional providers for your specific env
      fail "#{provider} is not a supported provider. [AWS|Rackspace]"
    end
  end

  def aws_parse(servers, srv)
    if srv.state == 'running'
      # more attributes are available for specific report tuning
      # check fog documentation: http://rubydoc.info/gems/fog/1.8.0
      servers[srv.public_ip_address] = [srv.attributes[:dns_name],
                                        srv.attributes[:id],
                                        srv.attributes[:tags]['Name']]
    end
  end

  def rax_parse(servers, srv)
    if srv.state == 'ACTIVE'
      # more attributes are available for specific report tuning
      # check fog documentation: http://rubydoc.info/gems/fog/1.8.0
      servers[srv.attributes[:addresses]['public'][0]] = [srv.attributes[:name],
                                                          srv.attributes[:id]]
    end
  end

  # grab attributes for all running instances
  # IPs and other attributes are provider specific
  def get_public_ips(provider)
    servers = {}
    @conn.servers.all.each do |srv|
      if provider.downcase == 'AWS'.downcase
        aws_parse(servers, srv)
      elsif provider.downcase == 'Rackspace'.downcase
        rax_parse(servers, srv)
      else
        fail "#{provider} is not a supported provider. [AWS|Rackspace]"
      end
    end
    servers
  end
end

# create a connection to Halo API
class APICalls
  def initialize(portal, key_id, key_secret)
    @portal = "https://#{portal}"

    begin
      # get a API authorization token
      url = '/oauth/access_token?grant_type=client_credentials'
      base64str = Base64.encode64("#{key_id}:#{key_secret}")

      resp = RestClient.post("#{@portal}/#{url}", '', { authorization: "Basic #{base64str}" })
      data = JSON.parse(resp)
      @token = data['access_token']
      @header = { authorization: "Bearer #{@token}", content_type: 'application/json' }

    rescue => e
      puts "ERROR: #{e}"
    end
  end

  # return the GET response to the provided URL
  def get(url)
    RestClient.get("#{@portal}/v1/#{url}", @header){ |resp, req, res, &block|
      if (200..499).include? resp.code
        resp
      else
        resp.return!(req, res, &block)
      end
    }
  end
end

# arrays containing provider and Halo IP addresses
# that will be diff'd to see what servers do not
# have Halo installed
provider_ips = []
halo_ips = []

# Define providers, credential_paths and regions (if applicable)
# where your servers reside. add/update this based on your env
# example format for the file defined as credential_path:
# :default:
#     :aws_access_key_id:     ABC123ABC123ABC123AB
#     :aws_secret_access_key: ABC123ABC123ABC123ABC123ABC123ABC123ABC1
# or
# :default:
#     :rackspace_username:  user_name
#     :rackspace_api_key:   ABC123ABC123ABC123ABC123ABC123ABC123ABC1
providers = { 'AWS' => ['/path/to/fog_aws.yml', ['us-west-1', 'us-east-1']],
              'Rackspace' => ['/path/to/fog_rackspace.yml', ['N/A']] }

# Pass in portal, key_id, key_secret to setup API session
# key_id/key_secret can be created from portal.cloudpassage.com
# Settings > Site Administration > API Keys
# At least a read-only key is required
host = 'api.cloudpassage.com'
key = 'abc123abc'
secret = 'abc123abc123abc123abc123abc123ab'
@api = APICalls.new(host, key, secret)

# grab all active servers and parse out their connecting IP address.
# this is their public IP address, which will match the providers
resp = @api.get('/servers')
if resp.code.to_int == 200
  data = JSON.parse(resp)
  data['servers'].each do |srv|
    halo_ips << srv['connecting_ip_address']
  end
else
  puts "ERROR: #{resp}"
  exit
end

# loop through providers to get running server attributes
providers.each do |prod|
  provider = prod[0]
  creds = prod[1][0]

  # loop through each region
  prod[1][1].each do |region|
    provider_ips = []

    # for each provider/region, grab the srv.public_ip_address
    # for "running" or "ACTIVE" servers
    @fog = FogCalls.new(provider, creds, region)
    running_srvs = @fog.get_public_ips(provider)
    running_srvs.each do |ip|
      provider_ips << ip[0]
    end

    # check to see if it's a server w/out a corresponding
    # Halo IP. Print out identifying attributes
    diff = provider_ips - halo_ips
    unless diff.empty?
      diff.each do |diff_ip|
        msg1 = "Halo is not installed on: #{provider}-#{region}"
        msg2 = "#{diff_ip}, #{running_srvs[diff_ip]}"
        puts "#{msg1}, #{msg2}"
      end
    end
  end
end
