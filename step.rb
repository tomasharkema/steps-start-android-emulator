require 'timeout'

# -----------------------
# --- Constants
# -----------------------

@adb = File.join(ENV['android_home'], 'platform-tools/adb')

# -----------------------
# --- Functions
# -----------------------

def log_fail(message)
  puts
  puts "\e[31m#{message}\e[0m"
  exit(1)
end

def log_warn(message)
  puts "\e[33m#{message}\e[0m"
end

def log_info(message)
  puts
  puts "\e[34m#{message}\e[0m"
end

def log_details(message)
  puts "  \e[97m#{message}\e[0m"
end

def log_done(message)
  puts "  \e[32m#{message}\e[0m"
end

def list_of_avd_images
  user_home_dir = ENV['HOME']
  return nil unless user_home_dir

  avd_path = File.join(user_home_dir, '.android', 'avd')
  return nil unless File.exist? avd_path

  images_paths = Dir[File.join(avd_path, '*.ini')]

  images_names = []
  images_paths.each do |image_path|
    ext = File.extname(image_path)
    file_name = File.basename(image_path, ext)
    images_names << file_name
  end

  return nil unless images_names
  images_names
end

def emulator_list
  devices = {}

  output = `#{@adb} devices 2>&1`.strip
  return {} unless output

  output_split = output.split("\n")
  return {} unless output_split

  output_split.each do |device|
    regex = /^(?<emulator>emulator-\d*)\s(?<state>.*)/
    match = device.match(regex)
    next unless match

    serial = match.captures[0]
    state = match.captures[1]

    devices[serial] = state
  end

  devices
end

def find_started_serial(running_devices)
  started_emulator = nil
  devices = emulator_list
  serials = devices.keys - running_devices.keys

  if serials.length == 1
    started_serial = serials[0]
    started_state = devices[serials[0]]

    if started_serial.to_s != '' && started_state.to_s != ''
      started_emulator = { started_serial => started_state }
    end
  end

  unless started_emulator.nil?
    started_emulator.each do |serial, state|
      return serial if state == 'device'
    end
  end

  nil
end

# -----------------------
# --- Main
# -----------------------

#
# Input validation
emulator_name = ENV['emulator_name']
if emulator_name.to_s == ''
  log_fail('Missing required input: emulator_name')
end

emulator_skin = ENV['skin']
emulator_ram = ENV['ram']

log_info('Configs:')
log_details("emulator_name: #{emulator_name}")
log_details("skin: #{emulator_skin}") if emulator_skin.to_s != ''
log_details("ram: #{emulator_ram}") if emulator_ram.to_s != ''

avd_images = list_of_avd_images
if avd_images
  unless avd_images.include? emulator_name
    log_info "Available AVD images: #{avd_images}"
    log_fail "AVD image with name (#{emulator_name}) not found!"
  end
end

#
# Print running devices
running_devices = emulator_list
if running_devices.length > 0
  log_info('Running emulators:')
  running_devices.each do |device, _|
    log_details("* #{device}")
  end
end

#
# Start adb-server
`#{@adb} start-server`

begin
  Timeout.timeout(800) do
    #
    # Start AVD image
    os = `uname -s 2>&1`

    emulator = File.join(ENV['android_home'], 'tools/emulator')
    emulator = File.join(ENV['android_home'], 'tools/emulator64-arm') if os.include? 'Linux'

    params = [emulator, '-avd', emulator_name]
    params << '-no-boot-anim' # Disable the boot animation during emulator startup.
    params << '-noaudio' # Disable audio support in the current emulator instance.
    params << '-no-window' # Disable the emulator's graphical window display.

    params << "-skin #{emulator_skin}" unless emulator_skin.to_s == ''
    params << '-noskin' if emulator_skin.to_s == ''
    params << '-memory #{emulator_ram}' if emulator_ram.to_s == ''

    command = params.join(' ')

    log_info('Starting emulator')
    log_details(command)

    t1 = Thread.new do
      system(command)
    end

    #
    # Check for started emulator serial
    serial = nil
    looking_for_serial = true

    while looking_for_serial do
      sleep 5

      serial = find_started_serial(running_devices)
      looking_for_serial = false if serial.to_s != ''
    end

    log_done("Emulator started: (#{serial})")

    #
    # Wait for boot finish
    log_info('Waiting for emulator boot')

    boot_in_progress = true

    while boot_in_progress do
      sleep 5

      dev_boot = "#{@adb} -s #{serial} shell \"getprop dev.bootcomplete\""
      dev_boot_complete_out = `#{dev_boot}`.strip

      sys_boot = "#{@adb} -s #{serial} shell \"getprop sys.boot_completed\""
      sys_boot_complete_out = `#{sys_boot}`.strip

      boot_anim = "#{@adb} -s #{serial} shell \"getprop init.svc.bootanim\""
      boot_anim_out = `#{boot_anim}`.strip

      boot_in_progress = false if dev_boot_complete_out.eql?('1') && sys_boot_complete_out.eql?('1') && boot_anim_out.eql?('stopped')
    end

    `#{@adb} -s #{serial} shell input keyevent 82 &`
    `#{@adb} -s #{serial} shell input keyevent 1 &`

    `envman add --key BITRISE_EMULATOR_SERIAL --value #{serial}`

    log_done('Emulator is ready to use 🚀')
    exit(0)
  end
rescue Timeout::Error
  log_fail('Starting emulator timed out')
end
