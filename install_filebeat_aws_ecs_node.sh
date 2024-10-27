#!/bin/bash
set +x

FILEBEAT_CONFIG_DIRECTORY="/filebeat/config"
FILEBEAT_DATA_DIRECTORY="/filebeat/data"
FILEBEAT_LOG_DIRECTORY="/filebeat/logs"
WORKING_DIR="/tmp"

# Populate variable that pulls the nexus auth token from EC2 parameter store
DOCKER_LOGIN=$(aws ssm --region ca-central-1 get-parameter --name '<PARAMNAME>' --with-decryption | jq -r '.[] | .Value')

# ECS Cluster Configuration, edit ECS_CLUSTER= to point to the given ECS cluster
echo "ECS_CLUSTER=ecs" >> /etc/ecs/ecs.config
echo "ECS_BACKEND_HOST=" >> /etc/ecs/ecs.config
echo "ECS_ENGINE_AUTH_TYPE=dockercfg" >> /etc/ecs/ecs.config
echo "ECS_ENGINE_AUTH_DATA={\"<REPO FQDN AND PORT>\":{\"auth\":\""$DOCKER_LOGIN"\"}}" >> /etc/ecs/ecs.config

# Install wget
yum install wget -y

# Update ECS agent
yum update -y ecs-init 
service docker restart && start ecs

##################################   FILEBEAT INSTALLATION     #################################################
# Download filebeat.  EDIT THE URL AND RPM FILENAME BELOW
cd $WORKING_DIR
wget https://artifacts.elastic.co/downloads/beats/filebeat/filebeat-6.6.2-x86_64.rpm

# Install filebeat
rpm --install filebeat-6.6.2-x86_64.rpm

# Create filebeat config directory
mkdir -p "$FILEBEAT_CONFIG_DIRECTORY"

# Create filebeat log directory
mkdir -p "$FILEBEAT_LOG_DIRECTORY"

# Create filebeat data directory
mkdir -p "$FILEBEAT_DATA_DIRECTORY"

# Create filebeat.yml config file
touch "$WORKING_DIR"/filebeat.yml
cat << 'EOF' > "$WORKING_DIR"/filebeat.yml
#=========================== Filebeat inputs =============================
filebeat.inputs:
- type: log
  # Change to true to enable this input configuration.
  enabled: true
  # Paths that should be crawled and fetched. Glob based paths.
  paths:
    - /var/log/*.log
    - /var/lib/docker/containers/*/*.log
#============================= Filebeat modules ===============================
filebeat.config.modules:
  # Glob pattern for configuration loading
  path: ${path.config}/modules.d/*.yml
  # Set to true to enable config reloading
  reload.enabled: false
  # Period on which files under path should be checked for changes
  #reload.period: 10s
#==================== Elasticsearch template setting ==========================
setup.template.settings:
  index.number_of_shards: 3
  #index.codec: best_compression
  #_source.enabled: false
#-------------------------- Elasticsearch output ------------------------------
output.elasticsearch:
  hosts: ["<FQDN AND PORT OF ES INGEST NODE 1>","<FQDN AND PORT OF ES INGEST NODE 2>"]
# Available log levels are: error, warning, info, debug
logging.level: info
logging.selectors: ["*"]
EOF
mv "$WORKING_DIR"/filebeat.yml "$FILEBEAT_CONFIG_DIRECTORY"

# Backup original /etc/init.d/filebeat file
mv /etc/init.d/filebeat /etc/init.d/filebeat.backup

# Create new /etc/init.d/filebeat file
touch "$WORKING_DIR"/filebeat
cat << 'EOF' > "$WORKING_DIR"/filebeat
#!/bin/bash
#
# filebeat          filebeat shipper
#
# chkconfig: 2345 98 02
# description: Starts and stops a single filebeat instance on this system
#
### BEGIN INIT INFO
# Provides:          filebeat
# Required-Start:    $local_fs $network $syslog
# Required-Stop:     $local_fs $network $syslog
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Filebeat sends log files to Logstash or directly to Elasticsearch.
# Description:       Filebeat is a shipper part of the Elastic Beats
#                    family. Please see: https://www.elastic.co/products/beats
### END INIT INFO
PATH=/usr/bin:/sbin:/bin:/usr/sbin
export PATH
[ -f /etc/sysconfig/filebeat ] && . /etc/sysconfig/filebeat
pidfile=${PIDFILE-/var/run/filebeat.pid}
agent=${BEATS_AGENT-/usr/share/filebeat/bin/filebeat}
# args="-c /etc/filebeat/filebeat.yml -path.home /usr/share/filebeat -path.config /etc/filebeat -path.data /var/lib/filebeat -path.logs /var/log/filebeat"
args="-c /filebeat/config/filebeat.yml -path.home /usr/share/filebeat -path.config /filebeat/config -path.data /filebeat/data -path.logs /filebeat/logs"
test_args="-e test config"
beat_user="${BEAT_USER:-root}"
wrapper="/usr/share/filebeat/bin/filebeat-god"
wrapperopts="-r / -n -p $pidfile"
user_wrapper="su"
user_wrapperopts="$beat_user -c"
RETVAL=0
# Source function library.
. /etc/rc.d/init.d/functions
# Determine if we can use the -p option to daemon, killproc, and status.
# RHEL < 5 can't.
if status | grep -q -- '-p' 2>/dev/null; then
    daemonopts="--pidfile $pidfile"
    pidopts="-p $pidfile"
fi
if command -v runuser >/dev/null 2>&1; then
    user_wrapper="runuser"
fi
[ "$beat_user" != "root" ] && wrapperopts="$wrapperopts -u $beat_user"
test() {
        $user_wrapper $user_wrapperopts "$agent $args $test_args"
}
start() {
    echo -n $"Starting filebeat: "
        test
        if [ $? -ne 0 ]; then
                echo
                exit 1
        fi
    daemon $daemonopts $wrapper $wrapperopts -- $agent $args
    RETVAL=$?
    echo
    return $RETVAL
}
stop() {
    echo -n $"Stopping filebeat: "
    killproc $pidopts $wrapper
    RETVAL=$?
    echo
    [ $RETVAL = 0 ] && rm -f ${pidfile}
}
restart() {
        test
        if [ $? -ne 0 ]; then
                return 1
        fi
    stop
    start
}
rh_status() {
    status $pidopts $wrapper
    RETVAL=$?
    return $RETVAL
}
rh_status_q() {
    rh_status >/dev/null 2>&1
}
case "$1" in
    start)
        start
    ;;
    stop)
        stop
    ;;
    restart)
        restart
    ;;
    condrestart|try-restart)
        rh_status_q || exit 0
        restart
    ;;
    status)
        rh_status
    ;;
    *)
        echo $"Usage: $0 {start|stop|status|restart|condrestart}"
        exit 1
esac
exit $RETVAL
EOF
mv "$WORKING_DIR"/filebeat /etc/init.d/filebeat

# Make file executable
chmod +x /etc/init.d/filebeat

# Start filebeat
service filebeat start