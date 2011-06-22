# Copyright 2008-2011 Red Hat, Inc, and individual contributors.
#
# This is free software; you can redistribute it and/or modify it
# under the terms of the GNU Lesser General Public License as
# published by the Free Software Foundation; either version 2.1 of
# the License, or (at your option) any later version.
#
# This software is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this software; if not, write to the Free
# Software Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA
# 02110-1301 USA, or see the FSF site: http://www.fsf.org.

require 'blankslate'
require 'torquebox/configuration/validator'

module TorqueBox
  module Configuration

    def self.load_configuration(file, config, entry_map)
      Thread.current[:torquebox_config] = config
      Thread.current[:torquebox_config_entry_map] = entry_map
      eval( File.read( file ) )
      config
    end

    def self.const_missing(name)
      FakeConstant.new( name )
    end

    class Entry < BlankSlate
      def initialize(name, config, entry_map, options = { })
        @name = name
        @config = config
        @entry_map = entry_map
        @parents = options.delete( :parents ) || []
        @allow_block = options.delete( :allow_block )
        @options = options
        @line_number = find_line_number

        if options[:require_parent] && ([options[:require_parent]].flatten & @parents).empty?
          raise ConfigurationError.new( "#{@name} only allowed inside #{options[:require_parent]}", @line_number )
        end
      end

      def find_line_number
        caller.each do |line|
          return $1 if line =~ /\(eval\):(\d+):/
        end
        nil
      end
      
      def process(*args, &block)
        @current_config = process_args( args )
        if block_given?
          if @allow_block
            eval_block( &block )
          else
            raise ConfigurationError.new( "#{@name} is not allowed a block", @line_number )
          end
        end
      end

      def process_args(unused)
        # no op
        @config
      end

      def validate_options(to_validate)
        if @options[:validate]
          validator = Validator.new( @options[:validate], @name, to_validate )
          raise ConfigurationError.new( validator.message, @line_number ) unless validator.valid?
        end
      end

      def eval_block(&block)
        block.arity < 1 ? self.instance_eval( &block ) : block.call( self )
      end

      def self.const_missing(name)
        FakeConstant.new( name )
      end

      def self.with_options(options)
        klass = self
        proxy = Object.new
        (class << proxy; self; end).__send__( :define_method, :new ) do |*args|
          if args.last.is_a?( Hash )
            args.last.merge!( options )
          else
            args << options
          end
          klass.new( *args )
        end
        proxy
      end

      alias_method :send, :__send__

      def method_missing(method, *args, &block)
        klass = @entry_map[method]
        if klass
          entry = klass.new( method, @current_config, @entry_map, :parents => @parents + [@name] )
          entry.process( *args, &block )
        else
          super
        end
      end

      def local_config
        @config[@name.to_s] ||= @options[:cumulative] ? [] : {}
      end

      def local_config=(value)
        @config[@name.to_s] = value
      end
    end

    class HashEntry < Entry
      def process_args(args)
        hash = args.first
        raise ConfigurationError.new( "'#{@name}' takes a hash (and only a hash)", @line_number ) if !hash.is_a?(Hash) || args.length != 1
        validate_options( hash )
        local_config.merge!( hash )
        local_config
      end
    end

    class ThingPlusHashEntry < Entry
      def process_args(args)
        thing, hash = args
        hash ||= {}
        validate_options( hash )
        if @options[:cumulative]
          local_config << [thing.to_s, hash]
          hash
        else
          local_config[thing.to_s] = { } unless local_config[thing.to_s]
          local_config[thing.to_s].merge!( hash )
          local_config[thing.to_s]
        end

      end
    end

    class ThingEntry < Entry
      def process_args(args)
        thing = args.first
        raise ConfigurationError.new( "'#{@name}' takes only one non-hash option", @line_number ) if thing.is_a?(Hash) || args.length != 1
        self.local_config = thing.to_s
        local_config
      end
    end
    
 
    class Configuration < Hash
      def initialize
        super { |hash, key| hash[key] = { } }
      end
    end

    class FakeConstant
      def initialize(name)
        @name = name.to_s
      end

      def to_s
        @name
      end
    end

    class ConfigurationError < RuntimeError
      def initialize(message, line_number = nil)
        message += " (line #{line_number})" if line_number
        super(message)
      end
    end

  end
end