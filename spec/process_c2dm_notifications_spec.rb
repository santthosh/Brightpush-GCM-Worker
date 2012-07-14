require 'spec_helper'
require File.dirname(__FILE__) + '/../lib/process_c2dm_notifications.rb'

describe "Process_C2DM_PushNotifications" do
  it "should process push notifications for Android devices" do
    Process_C2DM_PushNotifications.method_defined?(:perform)
  end
end