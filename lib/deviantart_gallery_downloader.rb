require 'mechanize'
require 'netrc'

class DeviantartGalleryDownloader
  attr_accessor :agent, :gallery_url, :author_name, :gallery_name
  HOME_URL = "https://www.deviantart.com/users/login"

  def initialize
    @agent = Mechanize.new
    @agent.user_agent = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_12_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/60.0.3112.113 Safari/537.36'
    @gallery_url = ARGV.size == 3 ? ARGV[2].to_s : ARGV[1].to_s
    @author_name = @gallery_url.split('.').first.split('//').last
    @gallery_name = @gallery_url.split('/').count == 6 ? @gallery_url.split('/').last : "default-gallery"
  end

  def fetch
    t1 = Time.now

    create_image_directories
    netrc_credential = create_or_update_credential
    login_to_deviantart(netrc_credential)
    image_page_links = get_image_page_links
    image_page_links.each_with_index do |page_link, index|
      retry_count = 0
      begin
        @agent.get(page_link)
        download_button_link = @agent.page.parser.css(".dev-page-button.dev-page-button-with-text.dev-page-download").map{|a| a["href"]}[0]
        image_link = @agent.page.parser.css(".dev-content-full").map{|img| img["src"]}[0]
        download_link = download_button_link || image_link
        file_path = get_file_path(index, image_page_links, download_link)
        @agent.get(download_link).save(file_path) unless File.exist?(file_path)
      rescue => ex
        puts ex.message
        if retry_count < 3
          retry_count += 1
          puts "retrying..."
          retry
        else
          next "failed after 3 retries, next"
        end
      end
    end

    puts "\nAll download completed. Check deviantart/#{@author_name}/#{@gallery_name}.\n\n"
    t2 = Time.now
    save = t2 - t1
    puts "Time costs: #{(save/60).floor} mins #{(save%60).floor} secs."   
  end

  private

  def create_or_update_credential
    if ARGV.size == 2 && ARGV[0] == "-n"
      if n = Netrc.read
        if n["deviantart.com"]
          puts "Using netrc's credential"
          n
        else
          abort "No entry found, please re-run the program and enter your login and password."
        end
      else
        abort "Reading .netrc failed, please re-run the program and enter your login and password."
      end
    elsif ARGV.size == 3
      begin
        n = Netrc.read
        if n["deviantart.com"]
          puts "Updating netrc's entry"
          n["deviantart.com"] = ARGV[0], ARGV[1]
          n.save
          n
        else
          puts "Creating netrc's entry"
          #n.new_item_prefix = "# This entry was added by deviantart-gallery-downloader automatically\n"
          n["deviantart.com"] = ARGV[0], ARGV[1]
          n.save
          n
        end
      rescue => ex
        puts "#{ex.message}, writing .netrc file failed, continue.\n"
      end
    else
      display_help_msssage
      abort
    end  
  end

  def display_help_msssage
    puts "The downloader uses GALLERY'S PAGE"
    puts ""
    puts "On the intital run, we need to add your login credential to your users ~/.netrc file, so we don't leave your username and password in the process ID,"
    puts "which could be seen by other users on the system (note: the initial run of this script will show up in your bash history)."
    puts ""
    puts "ruby fetch.rb YOUR_USERNAME YOUR_PASSWORD http://azoexevan.deviantart.com/gallery/"
    puts ""
    puts "An entry in ~/.netrc is created for you. You can then use '-n' and it will poll the netrc file for your login credentials."
    puts ""
    puts "ruby fetch.rb -n http://azoexevan.deviantart.com/gallery/"
  end

  def create_image_directories
    Dir.mkdir("deviantart") unless File.exists?("deviantart") do
      Dir.chdir("deviantart") do
        Dir.mkdir(@author_name) unless File.exists?(@author_name) do
          Dir.mkdir(@gallery_name) unless File.exists?(@gallery_name)
        end
      end
    end
  end

  def login_to_deviantart(netrc_credential)
    puts "Logging in" 
    retry_count = 0
    begin
      @agent.get(HOME_URL)
      @agent.page.form_with(:id => 'login') do |f|
        if ARGV.size == 3
          f.username = ARGV[0]
          f.password = ARGV[1]
        else
          f.username = netrc_credential["deviantart.com"].login
          f.password = netrc_credential["deviantart.com"].password
        end
      end.click_button
      if @agent.cookie_jar.count < 3
        puts "Log on unsuccessful (maybe wrong login/pass combination?)"
        puts "You might not be able to fetch the age restricted resources"
      else
        puts "Log on successful"
      end
      @agent.pluggable_parser.default = Mechanize::Download
    rescue => ex
      puts ex.message
      if retry_count < 3
        retry_count += 1
        puts "Will retry after 1 second"
        sleep 1
        retry  
      else
        puts "Login failed after 3 retries"
        puts "You might not be able to fetch the age restricted resources"
      end
    end   
  end

  def get_image_page_links
    retry_count = 0
    puts "Connecting to gallery"
    begin
      @agent.get(@gallery_url)
      page_links = []
      link_selector = 'a.torpedo-thumb-link'
      last_page_number = get_last_page_number
      last_page_number.times do |i|
        current_page_number = i + 1
        puts "(#{current_page_number}/#{last_page_number})Analyzing #{@gallery_url}"
        page_link = @agent.page.parser.css(link_selector).map{|a| a["href"]}
        page_links << page_link
        gallery_link = @gallery_url.include?("?") ? @gallery_url + "&" : @gallery_url + "?"
        if current_page_number > 1
          gallery_link += "offset=" + (current_page_number * 24).to_s
        end
        @agent.get(gallery_link)
      end
      page_links.flatten!
    rescue => ex
      puts ex.message
      if retry_count < 3
        retry_count += 1
        puts "will retry after 1 second"
        sleep 1
        retry
      else
        abort "failed to connect to gallery after 3 retries, abort"
      end
    end
  end

  def get_file_path(index, image_page_links, download_link)
    title_art_elem = @agent.page.parser.css(".dev-title-container h1 a")
    title_elem = title_art_elem.first
    title_art = title_art_elem.last.text
    title = title_elem.text

    puts "(#{index + 1}/#{image_page_links.count})Downloading \"#{title}\""

    #Sanitize filename
    file_name = download_link.split('?').first.split('/').last
    file_id = title_elem['href'].split('-').last
    file_ext = file_name.split('.').last
    file_title = title.strip().gsub(/\.+$/, '').gsub(/^\.+/, '').strip().squeeze(" ").tr('/\\', '-')

    file_name = title_art+'-'+file_title+'.'+file_id+'.'+file_ext
    file_path = "deviantart/#{@author_name}/#{@gallery_name}/#{file_name}"
  end

  def get_last_page_number
    page_numbers_selector = '.zones-top-left .pagination ul.pages li.number'
    last_page = @agent.page.parser.css(page_numbers_selector).last

    if last_page
      last_page_number = last_page.text.to_i
    elsif @agent.page.parser.css('.zones-top-left .pagination ul.pages li.next a').first['href'].nil?
      last_page_number = 1
    else
      abort "Cannot determine page numbers, abort"
    end   
  end
end
