#!/bin/bash
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$DIR/common.sh"

config_file="config.json"
app=
app_script=
num_nodes=
ppn=
script_flags=
jobname=
taskname=

function usage(){
    me=`basename $0`
    echo ""
    echo "Usage:"
    echo "$me -c config.json -a APPNAME "
    echo "    -c: config file to use"
    echo "    -a: application (application list)"
    echo "    -j: job name (create job if not exists) - if not specified application name is used"
    echo "    -t: task name - if not specified automatically built"
    echo "    -s: script to run"
    echo "    -n: number of nodes"
    echo "    -m: machine_size"
    echo "    -p: processes per node"
    echo "    -x: script flags to pass"
    echo "    -h: help"
    echo ""
}

while getopts "a: c: s: n: m: p: x: j: t: h" OPTION
do
    case ${OPTION} in
        c)
        config_file=$OPTARG
            ;;
        a)
        app=$OPTARG
            ;;
        j)
        jobname=$OPTARG
            ;;
        t)
        taskname=$OPTARG
            ;;
        s)
        app_script=$OPTARG
            ;;
        n)
        num_nodes=$OPTARG
            ;;
        m)
        machine_size=$OPTARG
            ;;
        p)
        ppn=$OPTARG
            ;;
        x)
        script_flags=$OPTARG
            ;;
        h)
        usage
        exit 0
            ;;
    esac
done

shift $(( OPTIND - 1 ));

if [ -z "$jobname" ]; then
    get_pool_id $app
    jobname=$POOL_ID
    pool_id=$POOL_ID
fi

# Set to default values if not set through input args
ppn=${ppn:-"1"}
num_nodes=${num_nodes:-"1"}

# Print out input values
echo "config file: $config_file"
echo "app: $app"
echo "app script: $app_script"
echo "num nodes: $num_nodes"
echo "processes per node: $ppn"
echo "script flags: $script_flags"
echo "job name: $jobname"
echo "task name: $taskname"

function create_jobfile {
    # create container for results and policy (if it doesn't exist)
    read_value results_storage_rg ".results.resource_group"
    read_value results_storage_name ".results.storage_account"
    read_value results_container ".results.container"

    results_storage_key=$(az storage account keys list \
        --resource-group $results_storage_rg \
        --account-name $results_storage_name \
        --query "[0].value" \
        --output tsv)

    container_exists="$(az storage container exists \
        --account-name $results_storage_name \
        --account-key "$results_storage_key" \
        --name $results_container --output tsv)"
    if [ "$container_exists" == "False" ]; then
        echo "Creating container ($results_container)..."
        az storage container create \
            --account-name $results_storage_name \
            --account-key "$results_storage_key" \
            --name $results_container \
            --output table

        echo "Adding container policy for read write access"
        az storage container policy create \
            --container-name $results_container \
            --name rw \
            --permissions rw \
            --account-key "$results_storage_key" \
            --account-name $results_storage_name \
            --start $(date --utc -d "-2 hours" +%Y-%m-%dT%H:%M:%SZ) \
            --expiry $(date --utc -d "+1 year" +%Y-%m-%dT%H:%M:%SZ) \
            --output table
    else
        echo "Container ($results_container) already exists."
    fi

    results_saskey=$(az storage container generate-sas \
        --policy-name rw \
        --name $results_container \
        --account-name $results_storage_name \
        --account-key $results_storage_key \
        --output tsv)
    echo "SAS Key = $results_saskey"
    results_storage_endpoint=$(az storage account show \
        --resource-group $results_storage_rg \
        --name $results_storage_name \
        --query "primaryEndpoints.blob" \
        --output tsv)
    echo "Results storage endpoint is $results_storage_endpoint"

    # upload the batch wrapper and the application scripts
    echo "Uploading batch wrapper"
    filename="./batch/batch_wrapper.sh"
    blobname="${app}/${job_id}/${task_id}/scripts/batch_wrapper.sh"
    az storage blob upload \
        --container-name $results_container \
        --account-name $results_storage_name \
        --account-key $results_storage_key \
        --file $filename \
        --name $blobname \
        --output table

    echo "Uploading application runner"
    filename="./apps/${app}/run_${app_script}.sh"
    blobname="${app}/${job_id}/${task_id}/scripts/run_${app_script}.sh"
    az storage blob upload \
        --container-name $results_container \
        --account-name $results_storage_name \
        --account-key $results_storage_key \
        --file $filename \
        --name $blobname \
        --output table

    read_value licserver ".infrastructure.licserver"
    read_value data_storage_name ".appstorage.storage_account"
    read_value data_container ".appstorage.data_container"
    read_value hpc_data_saskey ".appstorage.data_saskey"

    if [ "$hpc_data_saskey" == "" ]; then
        # Create input data SAS KEY
        read_value data_storage_rg ".appstorage.resource_group"
        data_storage_key=$(az storage account keys list \
            --resource-group $data_storage_rg \
            --account-name $data_storage_name \
            --query "[0].value" \
            --output tsv)
        echo "Adding container policy for read access"
        az storage container policy create \
            --container-name $data_container \
            --name read \
            --permissions r \
            --account-key "$data_storage_key" \
            --account-name $data_storage_name \
            --start $(date --utc -d "-2 hours" +%Y-%m-%dT%H:%M:%SZ) \
            --expiry $(date --utc -d "+1 year" +%Y-%m-%dT%H:%M:%SZ) \
            --output table
        hpc_data_saskey=$(az storage container generate-sas \
            --policy-name read \
            --name $data_container \
            --account-name $data_storage_name \
            --account-key $data_storage_key \
            --output tsv)
    fi
    echo "HPC data SAS Key = $hpc_data_saskey"
    hpc_data_storage_endpoint="http://$data_storage_name.blob.core.windows.net/$data_container"
    echo "HPC data storage endpoint is $hpc_data_storage_endpoint"

    read_value analytics_workspace ".infrastructure.analytics.workspace"
    read_value analytics_key ".infrastructure.analytics.key"

    replace="s,#TASK_ID#,$task_id,g"
    replace+=";s,#JOB_ID#,$job_id,g"
    replace+=";s,#APP#,$app,g"
    replace+=";s,#APP_SCRIPT#,$app_script,g"
    replace+=";s,#RESULTS_ENDPOINT#,$results_storage_endpoint,g"
    replace+=";s,#RESULTS_CONTAINER#,$results_container,g"
    replace+=";s,#RESULTS_SASKEY#,$results_saskey,g"
    replace+=";s,#NUM_NODES#,$num_nodes,g"
    replace+=";s,#PPN#,$ppn,g"
    replace+=";s,#LICSERVER#,$licserver,g"
    replace+=";s,#HPC_DATA_SASKEY#,$hpc_data_saskey,g"
    replace+=";s,#HPC_DATA_STORAGE_ENDPOINT#,${hpc_data_storage_endpoint},g"
    replace+=";s,#SCRIPT_FLAGS#,${script_flags},g"
    replace+=";s,#ANALYTICS_WORKSPACE#,${analytics_workspace},g"
    replace+=";s,#ANALYTICS_KEY#,${analytics_key},g"
    # escape string for sed
    echo "Replace string: \"$replace\""
    replace=$(sed "s/\&/\\\&/g" <<< "$replace")
    sed "$replace" batch/task-template.json > ${task_id}.json

}

echo "Ready to read in the values"
read_value subscription_id ".subscription_id"
read_value location ".location"
read_value sp_client_id ".service_principal.client_id"
read_value sp_client_secret ".service_principal.client_secret"
read_value sp_tenant_id ".service_principal.tenant_id"

timestamp=$(date +%Y%m%d-%H%M%S)
if [ -z "$taskname" ]; then
    taskname=${app_script}_${num_nodes}_${ppn}
fi

job_id=$jobname
task_id=${taskname}_${timestamp}

azure_login

read_value cluster_type ".cluster_type"

if [ "$cluster_type" == "batch" ]; then

    #
    # RUN SCRIPT ON BATCH POOL FOR THE CLUSTER
    #
    read_value batch_rg ".batch.resource_group"
    read_value batch_account ".batch.account_name"

    batch_login

    jobstate=$(az batch job show --job-id $jobname --query "state" 2>/dev/null)
    if [ -z "$jobstate" ]; then
        echo "Create job $job_id for pool $pool_id"
        az batch job create \
            --id $job_id \
            --pool-id $pool_id \
            --output table
    fi

    create_jobfile

    echo "Task ID: $task_id"
    echo "Job ID: $job_id"
    az batch task create --job-id $job_id --json-file ${task_id}.json --output table

    echo "Job ID: $job_id"
    rm ${task_id}.json

elif [ "$cluster_type" == "cyclecloud" ]; then
    echo "Running app in the Cycle GridEngine Cluster"
    create_jobfile

    if ! which cyclecloud > /dev/null ;then
    PATH=$HOME/bin:./bin:$PATH
    fi

    rsaPublicKey="$HOME/.ssh/id_rsa.pub"
    if [ ! -f $rsaPublicKey ]; then
        echo "No public ssh key found ($rsaPublicKey)."
        echo "Run ssh-key with all default options and re-run this script."
        exit 1
    fi

    cluster_ip=$(cyclecloud show_nodes master -c appcatalog_gridengine --format json | jq '.[0]["Instance"]["PublicIp"]' | sed 's/\"//g')
    scp ${task_id}.json $cluster_ip:appcatalog/


    # images names are tagged with the node Sku
    get_pool_id $app
    pool_id=$POOL_ID

    read_value image_rg ".images.resource_group"
    image_id=$(az image list \
        --resource-group $image_rg \
        --query "[?contains(name,'$pool_id-')].[name,id]" \
        --output tsv \
        | sort | tail -n1 | cut -d$'\t' -f2)
    echo "$app image: $image_id"

    if [ -z $image_id ];then
        echo "Unable to locate image for app $app"
        exit 1
    fi

    # Machine size defaults to H16r, unless specified
    if [ -z $machine_size ];then
        machine_size="Standard_H16r"
    fi
    command="submit_azbatch_task.py -a $app -b ~/appcatalog/${task_id}.json -i $image_id -p $ppn -n $num_nodes -m $machine_size"

    echo "Submmiting job in cluster: "
    echo "$command"
    ssh $cluster_ip "cd ~/appcatalog/; $command"
    rm -f ${task_id}.json

else
    echo "Unknown cluster type"
fi
