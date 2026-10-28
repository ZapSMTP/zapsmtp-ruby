# frozen_string_literal: true

# Everything but the Rails integration (lib/zapsmtp.rb adds it when Rails is loaded).
require_relative "version"
require_relative "errors"
require_relative "response"
require_relative "model"
require_relative "page"
require_relative "util"
require_relative "attachment"
require_relative "retry"
require_relative "transport"
require_relative "base_client"
require_relative "webhook"
require_relative "webhook_middleware"
require_relative "generated/models"
require_relative "generated/resources"
require_relative "generated/client"
