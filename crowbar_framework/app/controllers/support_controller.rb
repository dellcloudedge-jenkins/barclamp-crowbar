# Copyright 2011, Dell 
# 
# Licensed under the Apache License, Version 2.0 (the "License"); 
# you may not use this file except in compliance with the License. 
# You may obtain a copy of the License at 
# 
#  http://www.apache.org/licenses/LICENSE-2.0 
# 
# Unless required by applicable law or agreed to in writing, software 
# distributed under the License is distributed on an "AS IS" BASIS, 
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. 
# See the License for the specific language governing permissions and 
# limitations under the License. 
# 
# Author: RobHirschfeld 
# 

class SupportController < ApplicationController
  
  require 'chef'

  # Legacy Support (UI version moved to loggin barclamp)
  def logs
    @file = "crowbar-logs-#{ctime}.tar.bz2"
    system("sudo -i /opt/dell/bin/gather_logs.sh #{@file}")
    redirect_to "/export/#{@file}"
  end
  
  def get_cli
    system("sudo -i /opt/dell/bin/gather_cli.sh #{request.env['SERVER_ADDR']} #{request.env['SERVER_PORT']}")
    redirect_to "/crowbar-cli.tar.gz"
  end
  
  def index
    @waiting = params['waiting'] == 'true'
    remove_file 'export', params[:id] if params[:id]
    @exports = { :count=>0, :logs=>[], :cli=>[], :chef=>[], :other=>[] }
    Dir.entries(export_dir).each do |f|
      if f =~ /^\./
        next # ignore rest of loop
      elsif f =~ /^crowbar-logs-.*/
        @exports[:logs] << f 
      elsif f =~ /^crowbar-cli-.*/
        @exports[:cli] << f
      elsif f =~ /^crowbar-chef-.*/
        @exports[:chef] << f 
      else
        @exports[:other] << f
      end
      @exports[:count] += 1
      @file = params['file'] if params['file']
      @waiting = false if @file == f
    end
    respond_to do |format|
      format.html # index.html.haml
      format.xml  { render :xml => @exports }
      format.json { render :json => @exports }
    end
  end
  
  def upload
    @file = nil
    if request.post?
      if params[:file] 
        begin
          tmpfile = params[:file]
          if tmpfile.class.to_s == 'Tempfile'
            @file = tmpfile.original_filename
            file = File.join import_dir, @file
            File.open(file, "wb") { |f| }
            while blk = tmpfile.read(65536)
              File.open(file, "ab") { |f| f.write(blk) }
            end
            tmpfile.delete
            flash[:notice] = t('.succeeded', :scope=>'support.upload') + ": " + @file
          end
        rescue
          Rails.logger.error("Upload of file failed")
          flash[:notice] = t('.failed', :scope=>'support.upload')
        end
      else
        flash[:notice] = t('.no_file', :scope=>'support.upload')
      end
    end
    redirect_to :action=>'import'
  end
  
  def import
    @installed = ServiceObject.barclamp_catalog['barclamps']
    @imports = {}
    if params[:id]
      tar = File.join RAILS_ROOT, import_dir, params[:id]
      if File.exist? tar
        begin
          importer = File.join '/opt', 'dell', 'bin', 'barclamp_install.rb'
          @output = "Command: #{importer} #{tar}<br/>Results:<br/>"
          @output += %x[sudo #{importer} #{tar}]
          @output = @output.gsub(/\n/,"<br/>")
          flash[:notice] = "#{t('success', :scope=>'support.import')}: #{params[:id]}"
          #TODO! If production mode, restart required!!
        rescue
          flash[:notice] = "#{t('error_import', :scope=>'support.import')}: #{tar}" 
        end
      else
        flash[:notice] = "#{t('error_file_missing', :scope=>'support.import')}: #{tar}" 
      end
    end
    Dir.entries(import_dir).each do |tar|
      if tar =~ /^.*tar.gz$/ 
        name = tar[/^(.*).tar.gz$/,1] + '.yml'
        unless File.exist? File.join(import_dir, name)
          archive = File.join import_dir,tar
          crowbar = %x[tar -t -f #{archive} | grep crowbar.yml].strip
          if crowbar
            %x[tar -x #{crowbar} -f #{archive} -O > #{File.join(import_dir, name)}]
          end
        end
        begin
          cb = YAML.load_file(File.join(import_dir, name))
          key = cb['barclamp']['name']
          @imports[key] = { :tar=>tar, :barclamp=>cb['barclamp'] }
          unless @installed.key? key
            @installed[key] = {:installed=>false, :name=>key, 'order'=>cb['crowbar']['order']}
          end
        rescue
          # something happened to the YAML file!
        end
      end
    end
    respond_to do |format|
      format.html # index.html.haml
      format.xml  { render :xml => @imports }
      format.json { render :json => @imports }
    end    
  end
  
  def export_chef
    if CHEF_ONLINE
      begin
        Dir.entries('db').each { |f| File.delete(File.expand_path(File.join('db',f))) if f=~/.*\.json$/ }
        NodeObject.all.each { |n| NodeObject.dump n, 'node', n.name }
        RoleObject.all.each { |r| RoleObject.dump r, 'role', r.name }
        ProposalObject.all.each { |p| ProposalObject.dump p, 'data_bag_item_crowbar-bc', p.name[/bc-(.*)/,1] }
        @file = cfile ="crowbar-chef-#{Time.now.strftime("%Y%m%d-%H%M%S")}.tgz"
        pid = fork do
          system "tar -czf #{File.join('/tmp',cfile)} #{File.join('db','*.json')}" 
          File.rename File.join('/tmp',cfile), File.join(export_dir,cfile)
        end        
        redirect_to "/utils?waiting=true&file=#{@file}"
      rescue Exception=>e
        flash[:notice] = I18n.t('support.export.fail') + ": " + e.message
        redirect_to "/utils"
      end
    else
      flash[:notice] = 'feature not available in offline mode'
    end
  end
  
  private 
  
  def ctime
    Time.now.strftime("%Y%m%d-%H%M%S")
  end
  
  def import_dir
    check_dir 'import'
  end
  
  def export_dir
    check_dir 'export'
  end

  def check_dir(type)
    d = File.join 'public', type
    unless File.directory? d
      Dir.mkdir d
    end
    return d    
  end
  
  def remove_file(type, name)
    begin
      f = File.join(check_dir(type), name)
      File.delete f
      flash[:notice] = t('support.index.delete_succeeded') + ": " + f
    rescue
      flash[:notice] = t('support.index.delete_failed') + ": " + f
    end
  end
  
end 
