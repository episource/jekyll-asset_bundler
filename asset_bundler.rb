#
# Jekyll Asset Bundler
#
# Author : Colin Kennedy
# Repo   : http://github.com/moshen/jekyll-asset_bundler
# Version: 0.12
# License: MIT, see LICENSE file
#

require 'yaml'
require 'digest/md5'
require 'net/http'
require 'uri'

module Jekyll

  class BundleTag < Liquid::Block
    def initialize(tag_name, text, tokens)
      super
      @text = text 
      @files = {}
    end

    def render(context)
      src = context.registers[:site].source
      raw_markup = super(context)
      begin
        @assets = YAML::load(raw_markup)
      rescue
        puts <<-END
Asset Bundler - Error: Problem parsing a YAML bundle
#{raw_markup}

#{$!}
END
      end

      if !@assets.kind_of?(Array)
        puts "Asset Bundler - Error: YAML bundle is not an Array\n#{raw_markup}"
        @assets = []
      end

      add_files_from_list(src, @assets)

      markup = ""

      @files.each {|k,v|
        markup.concat(Bundle.new(v, k, context).markup())
      }

      markup
    end

    def add_files_from_list(src, list)
      list.each {|a|
        path = File.join(src, a)
        if (File.basename(a) !~ /^\.+/ and File.file?(path)) or a =~ /^(https?:)?\/\//i
          add_file_by_type(a)
        else
          puts "Asset Bundler Error - File: #{path} not found, ignoring..."
        end
      }
    end

    def add_file_by_type(file)
      if file =~ /\.([^\.]+)$/
        type = $1.downcase()
        return if Bundle.supported_types.index(type).nil?
        if !@files.key?(type)
          @files[type] = []
        end

        @files[type].push(file)
      end
    end

  end

  class BundleGlobTag < BundleTag
    def add_files_from_list(src, list)
      list.each {|a|
        Dir.glob(File.join(src, a)) {|f|
          if f !~ /^\.+/ and File.file?(f)
            add_file_by_type(f.sub(src,''))
          end
        }
      }
    end

  end

  class DevAssetsTag < BundleTag
    def render(context)
      if Bundle.config(context)['dev']
        super(context)
      else
        ''
      end
    end

    def add_files_from_list(src, list)
      list.each {|a|
        add_file_by_type(a)
      }
    end
  end

  class Bundle
    @@bundles = {}
    @@default_config = {
      'compile'        => { 'coffee' => false, 'less' => false },
      'compress'       => { 'js'     => false, 'css'  => false },
      'base_path'      => '/bundles/',
      'server_url'     => '',
      'remove_bundled' => false,
      'dev'            => false,
      'markup_templates' => {
        'js'     =>
          Liquid::Template.parse("<script type='text/javascript' src='{{url}}'></script>\n"),
        'coffee' =>
          Liquid::Template.parse("<script type='text/coffeescript' src='{{url}}'></script>\n"),
        'css'    =>
          Liquid::Template.parse("<link rel='stylesheet' type='text/css' href='{{url}}' />\n"),
        'less'   =>
          Liquid::Template.parse("<link rel='stylesheet/less' type='text/css' href='{{url}}' />\n")
      }
    }
    @@current_config = nil
    @@supported_types = ['js', 'css']
    attr_reader :content, :hash, :filename, :base

    def initialize(files, type, context, force=false, filename=nil)
      @files      = files
      @type       = type
      @context    = context
      @content    = ''
      @hash       = ''
      @filename   = filename

      @config     = Bundle.config(@context)

      # in dev mode anonymous bundles are not merged: the generated markup
      # references source files
      @nomerge    = @config['dev'] && filename == nil
      @nocompress = @config['dev']

      @base       = @config['base_path']

      @filename_hash = Digest::MD5.hexdigest(@files.join())
      if !force && @@bundles.key?(@filename_hash)
        @filename = @@bundles[@filename_hash].filename
        @base     = @@bundles[@filename_hash].base
        @content  = @@bundles[@filename_hash].content
        @hash     = @@bundles[@filename_hash].hash
      else
        load_content()
      end
    end

    def self.config(context)
      if @@current_config.nil?
        ret_config = nil
        if context.registers[:site].config.key?("asset_bundler")
          ret_config = Utils.deep_merge_hashes(@@default_config,
                                               context.registers[:site].config["asset_bundler"])

          ret_config['markup_templates'].keys.each {|k|
            if !ret_config['markup_templates'][k].instance_of?(Liquid::Template)
              if ret_config['markup_templates'][k].instance_of?(String)
                ret_config['markup_templates'][k] =
                  Liquid::Template.parse(ret_config['markup_templates'][k]);
              else
                puts <<-END
Asset Bundler - Error: Problem parsing _config.yml

The value for configuration option:
  asset_bundler => markup_templates => #{k}

Is not recognized as a String for use as a valid template.
Reverting to the default template.
END
                ret_config['markup_templates'][k] = @@default_config['markup_templates'][k];
              end
            end
          }

          if context.registers[:site].config['asset_bundler'].key?('cdn') and ret_config['server_url'].empty?
            ret_config['server_url'] = context.registers[:site].config['asset_bundler']['cdn']
          end
        else
          ret_config = @@default_config
        end

        # Check to make sure the base_path begins with a slash
        #   This is to make sure that the path works with a potential base CDN url
        if ret_config['base_path'] !~ /^\//
          ret_config['base_path'].insert(0,'/')
        end

        if context.registers[:site].config.key?("dev")
          ret_config['dev'] = context.registers[:site].config["dev"] ? true : false
        end

        # Let's assume that when flag 'watch' or 'serving' is enabled, we want dev mode
        if context.registers[:site].config['watch']
          ret_config['dev'] = true
        end

        @@current_config = ret_config
      end

      @@current_config
    end

    def self.supported_types
      @@supported_types
    end

    def load_content()
      if @nomerge
        @@bundles[@filename_hash] = self
        return
      end

      src = @context.registers[:site].source

      @files.each {|f|
        if f =~ /^(https?:)?\/\//i
          # Make all requests via http
          f = "http:#{f}" if !$1
          f.sub!( /^https/i, "http" ) if $1 =~ /^https/i
          @content.concat(remote_asset_cache(URI(f)))
        else
          # Load file from path and render it if it contains tags

          # Extract the path parts
          f = File.split(f)

          # Render the page                               path  file
          page = Page.new(@context.registers[:site], src, f[0], f[1])
          page.render(@context.registers[:site].layouts,
                      @context.registers[:site].site_payload())

          @content.concat(page.output)
        end

        # In case the content does not end in a newline
        @content.concat("\n")
      }

      @hash = Digest::MD5.hexdigest(@content)
      @filename = @filename || "#{@hash}.#{@type}"
      cache_hash = Digest::MD5.hexdigest("#{@hash}#{@config['compress']}#{@nocompress}");
      cache_file = File.join(cache_dir(), "#{cache_hash}.#{@type}")

      if File.readable?(cache_file) and @config['compress'][@type]
        @content = File.read(cache_file)
      elsif @config['compress'][@type]
        # TODO: Compilation of Less and CoffeeScript would go here
        compress()
        File.open(cache_file, "w") {|f|
          f.write(@content)
        }
      end

      @context.registers[:site].static_files.push(self)
      remove_bundled() if @config['remove_bundled']

      @@bundles[@filename_hash] = self
    end

    def cache_dir()
      cache_dir = File.expand_path( "../_asset_bundler_cache",
                                    @context.registers[:site].plugins.first )
      if( !File.directory?(cache_dir) )
        FileUtils.mkdir_p(cache_dir)
      end

      cache_dir
    end

    def remote_asset_cache(uri)
      cache_file = File.join(cache_dir(),
                             "remote.#{Digest::MD5.hexdigest(uri.to_s)}.#{@type}")
      content = ""

      if File.readable?(cache_file)
        content = File.read(cache_file)
      else
        begin
          puts "Asset Bundler - Downloading: #{uri.to_s}"
          content = Net::HTTP.get(uri)
          File.open(cache_file, "w") {|f|
            f.write( content )
          }
        rescue
          puts "Asset Bundler - Error: There was a problem downloading #{f}\n  #{$!}"
        end
      end

      return content
    end

    # Removes StaticFiles from the _site if they are bundled
    #   and the remove_bundled option is true
    #   which... it isn't by default
    def remove_bundled()
      src = @context.registers[:site].source
      @files.each {|f|
        @context.registers[:site].static_files.select! {|s|
          if s.is_a?(StaticFile)
            s.path != File.join(src, f)
          else
            true
          end
        }
      }
    end

    def compress()
      return if @nocompress

      case @config['compress'][@type]
        when 'yui'
          compress_yui()
        when 'closure'
          compress_closure({})
        when 'closure_advanced'
          compress_closure({
            :compilation_level => 'ADVANCED_OPTIMIZATIONS',
            :externs => (@config['compress']['js_externs'] || []).map { |d| File.join(@context.registers[:site].source, d) }
          })
        else
          compress_command()
      end
    end

    def compress_command()
      temp_path = cache_dir()
      command = String.new(@config['compress'][@type])
      infile = false
      outfile = false
      used_files = []

      if command =~ /:infile/
        File.open(File.join(temp_path, "infile.#{@filename_hash}.#{@type}"), mode="w") {|f|
          f.write(@content)
          used_files.push( f.path )
          infile = f.path
        }
        command.sub!( /:infile/, "\"#{infile.gsub(File::SEPARATOR,
                               File::ALT_SEPARATOR || File::SEPARATOR)}\"")
      end
      if command =~ /:outfile/
        outfile = File.join(temp_path, "outfile.#{@filename_hash}.#{@type}")
        used_files.push( outfile )
        command.sub!( /:outfile/, "\"#{outfile.gsub(File::SEPARATOR,
                               File::ALT_SEPARATOR || File::SEPARATOR)}\"")
      end

      if infile and outfile
        `#{command}`
      else
        mode = "r"
        mode = "r+" if !infile
        IO.popen(command, mode) {|i|
          if !infile
            i.puts(@content)
            i.close_write()
          end
          if !outfile
            @content = ""
            i.each {|line|
              @content << line
            }
          end
        }
      end

      if outfile
        @content = File.read( outfile )
      end

      used_files.each {|f|
        File.unlink( f )
      }
    end

    def compress_yui()
      require 'yui/compressor'
      case @type
        when 'js'
          @content = YUI::JavaScriptCompressor.new(:java_opts => '-Xss8m').compress(@content)
        when 'css'
          @content = YUI::CssCompressor.new(:java_opts => '-Xss8m').compress(@content)
      end
    end

    def compress_closure(closure_args)
      require 'closure-compiler'
      case @type
        when 'js'
          @content = Closure::Compiler.new(closure_args).compile(@content)
      end
    end

    def markup()
      return nomerge_markup() if @nomerge

      @config['markup_templates'][@type].render(
        'url' => "#{@config['server_url']}#{@base}#{@filename}"
      )
    end

    def nomerge_markup()
      output = ''
      @files.each {|f|
        output.concat(
          @config['markup_templates'][@type].render('url' => "#{f}")
        )
      }

      return output
    end

    # Methods required by Jekyll::Site to write out the bundle
    #   This is where we give Jekyll::Bundle a Jekyll::StaticFile
    #   duck call and send it on its way.
    def relative_path
      File.join(@base, @filename)
    end

    def path
      self.relative_path
    end

    def destination(dest)
      File.join(dest, @base, @filename)
    end

    def write?
      true
    end

    def write(dest)
      dest_path = destination(dest)

      FileUtils.mkdir_p(File.dirname(dest_path))
      File.open(dest_path, "w") {|o|
        o.write(@content)
      }

      true
    end
    # End o' the duck call

  end

end

Liquid::Template.register_tag('bundle'     , Jekyll::BundleTag    )
Liquid::Template.register_tag('bundle_glob', Jekyll::BundleGlobTag)
Liquid::Template.register_tag('dev_assets' , Jekyll::DevAssetsTag )

# do this before post_write, such that remove_bundled has any effect!
Jekyll::Hooks.register :site, :post_render do |site|
  ((site.config['asset_bundler'] || {})['named_bundles'] || {}).each{ |k, v|
    if k =~ /\.([^\.]+)$/
      force_reload = true
      type = $1.downcase()
      context = Liquid::Context.new()
      context.registers[:site] = site
      Jekyll::Bundle.new(v, type, context, force_reload, k).write(site.dest)
    else
      raise "Cannot determine bundle type (js or css): #{k}"
    end
  }
end
