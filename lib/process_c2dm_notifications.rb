import 'lib/simpledb.rb'
import 'lib/sqs.rb'
import 'lib/s3.rb'
require 'json'

# Schedule a whole bunch of push notifications
module Process_C2DM_PushNotifications
  @queue = :c2dm_notifier
  
  # Set the status of the notification 
  def self.set_notification_status(item,status,identifier = nil)
    item.attributes.replace(:status => status)
    if identifier
      item.attributes.replace(:scheduler_id => identifier)
    end
    item.attributes.replace(:updated => Time.now.iso8601)
  end
  
  # Set the status of the notification queue to process
  def self.set_queue_status(item,status,identifier = nil)
    item.attributes.replace(:status => status)
    if identifier
      item.attributes.replace(:process_id => identifier)
    end
    item.attributes.replace(:updated => Time.now.iso8601)
  end
  
  # Get the notification queue to process
   def self.get_pending_queue(domain,identifier = nil)
     # Look for new item in notification queue that are yet to be scheduled in Amazon Simple DB
     results = domain.items.where("status = 'pending' AND application_type = ?","android")
     return results.first;
   end
   
  # Send the Push Message to all the given device tokens
  def self.send_push_message(bundle_id,device_tokens,notification_message)
    tokens = device_tokens.split(',')
    
    tokens.each do |token|
      begin
       token_list = [token]
       message_list = [JSON.parse(notification_message)]
       $client.notify(bundle_id, token_list,message_list)
      rescue Exception => e
       puts e.inspect
       puts e.backtrace
      end
    end
  end
  
  # Execute the job
  def self.perform
    domain = SimpleDB.get_domain(SimpleDB.domain_for_notification_queues)
  
    unless domain.nil?
      notification_queue_item = Process_C2DM_PushNotifications.get_pending_queue(domain)
      
      unless notification_queue_item.nil?
        process_identifier = SecureRandom.uuid
        puts "process_id = #{process_identifier}"
        
        # Set the scheduler_id in com.apple.notification
        Process_C2DM_PushNotifications.set_queue_status(notification_queue_item,"processing",process_identifier)
        
        # This is necessary so that Amazon SimpleDB updates their db
        sleep(10)
        
        # Read the scheduler_id, if it is the same set status to scheduling 
        #  -- if not quit (this means some other worker has started working)
        if process_identifier.to_s != notification_queue_item.attributes['process_id'].values.first.to_s
          puts "process_id(#{process_identifier}) mismatch with 
                notification_queue_item.process_id(#{notification_queue_item.attributes['process_id'].values.first})"
          return
        end
        
        queue = SQS.get_queue(notification_queue_item.name)
        
        notification_domain = SimpleDB.get_domain(SimpleDB.domain_for_notification)
        notification_id = notification_queue_item.attributes['notification_id'].values.first
        notification_item = notification_domain.items[notification_id]
        
        bundle_id = notification_item.attributes['bundle_id'].values.first.to_s
        certificate = notification_item.attributes['certificate'].values.first.to_s
        certificate_path = S3.mounted_certificate_path + certificate
        environment = notification_item.attributes['environment'].values.first.to_s
        notification_message = notification_item.attributes['message'].values.first.to_s
        
        $client.provision :app_id => bundle_id, :cert => certificate_path, :env => environment, :timeout => 15
        
        unless queue.nil?
          if queue.exists?
            queue.poll(:initial_timeout => true,
              :idle_timeout => 15) {
                |msg| Process_C2DM_PushNotifications.send_push_message(bundle_id,msg.body,notification_message)
            }
            queue.delete
          end

          # Delete the entry in the notification.queues table
          notification_queue_item.delete
          
          # Scan the notification.queues table to see if there are more entries in the table for the same notification_id
          pending_queues = domain.items.where("notification_id = ?",notification_id)
          
          # This is necessary for simple db to catch up
          sleep(5);

          # if there are, then quit, else then go ahead and mark this as complete
          if pending_queues.nil? || pending_queues.count == 0
              Process_C2DM_PushNotifications.set_notification_status(notification_item,"completed")
          end
        end
        
      end
    end
  end
  
end