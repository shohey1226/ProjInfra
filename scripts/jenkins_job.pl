use strict;
use warnings;
use JSON::PP;
use FindBin qw($Bin);
use Data::Dumper;
use Cwd;

my $docker = "/usr/bin/docker";
my $packer = "/usr/local/bin/packer";
my $rake = "/usr/bin/rake";
my $doman = "$Bin/doman.pl";
my $ansible = "/usr/bin/ansible-playbook";

if ($ENV{GIT_COMMIT} eq '' || $ENV{GIT_BRANCH} eq '' ){
    die "Both GIT_COMMIT and GIT_BRANCH should exist\n";
}

# first 7 digits of commit#
my $git_commit = substr ($ENV{GIT_COMMIT}, 0, 7);

#-----------------------------------------------
# Branch name - origin/{base,webapp,nginx,,,}
#-----------------------------------------------
my $branch = $ENV{GIT_BRANCH};
print "Working on $branch ...\n";

if ($branch eq "origin/master"){
    run_master_process();
}else{
    $branch =~ s/^origin\///;
    $branch =~ s/\/(\S+)$//;
    run_branch_process($branch, $git_commit);
}

exit 0;

#==============================================
# Master 
#==============================================
sub run_master_process{

    # do nothing for now
    # create do iamge do-webapp 
    # and run test which should be the same as docker test
    my $cmd;


    # Find what is the change
    my $user = $ENV{USER};
    my @lines = `$docker ps -a | grep $user | grep ':latest'`;
    my $names;
    for my $line (@lines){
        chomp $line;
        if ($line =~ /(\S+)(\d{10}\-\S{7})/){
            my $type = $1; 
            my $number = $2;
            if (defined $names->{$type}) {
                if ($names->{$type} lt $number){
                    $names->{$type} = $number;
                }
            }else{
                $names->{$type} = $number;
            }
        }
    }

    my $out = `$doman --show_my_image`;
    for my $type (keys %$names ){
        my $name = $type . $names->{$type};
        if ($out !~ /name:$name/){
            my ($ip, $droplet_id, $image_id) = _create_do_image($type, $name);
            if (_run_test($type, $ip, 22) == 0 ){
                print "Test passed for $type\n";
            }else{
                print "Error: Failed to execute rake for serverspec\n";
                print "Destroying droplet(id=$droplet_id)..\n";
                system "$doman --destroy_droplet -droplet_id $droplet_id"; 
                exit 1;
            }
        }
    }

    # copy dummy success result
    system "cp $Bin/../tests/etc/success.xml $Bin/../results.xml";

    exit 0;
}


#==============================================
# Branch 
#==============================================
sub run_branch_process{
    my ($type, $git_commit) = @_; 

    my $user = $ENV{USER};

    my $base_image_repo = "$user/base";
    my $base_image_id = `$docker images | grep $base_image_repo | grep latest | awk '{print \$3}'`;
    chomp $base_image_id;

    my $epoch = time();
    my $image_name = $type . $epoch . '-' . $git_commit . '.img';
    my $cmd;

    if ($type eq 'base'){
        # Create image file using Packer 
        $cmd = "$packer build -var 'image_name=/tmp/$image_name' packer/docker-base.json";
        print "Execute: $cmd \n";
        system($cmd) == 0 or die "Failed to execute: $cmd\n"; 

        # if the latest exsits,  tag current $user/base:latest to $user/base:$epoch 
        if ($base_image_id ne ''){
            $cmd = "$docker tag $base_image_id ${base_image_repo}:${epoch}-${git_commit}";
            print "Execute: $cmd\n";
            system($cmd) == 0 or die "Failed to execute: $cmd\n";  
        }

        # Create docker image
        $cmd = "$docker import - ${base_image_repo} < /tmp/$image_name";
        print "Execute: $cmd\n";
        $base_image_id = `$cmd`; 
        die "Failed to execute: $cmd" if ($base_image_id eq ''); 

        # Run the image 
        $cmd = "$docker run -d --name base${epoch}-${git_commit} -p 2222:22 ${base_image_repo}:latest /usr/sbin/sshd -D";
        print "Execute: $cmd\n";
        my $container_id = `$cmd`;
        die "Failed to execute : $cmd" if ($container_id eq '');

        # Run test
        chdir "tests/$type";
        $cmd = "TARGET_HOST=localhost TARGET_PORT=2222 ./run.sh";
        print "chdir to tests/$type and execute: $cmd\n";
        if (system($cmd) == 0){

            $cmd = "$docker stop $container_id";
            print $cmd , "\n";
            system($cmd) == 0 or die "Failed to execute: $cmd\n";  

            # destroy container and image 
            $cmd = "$docker rm $container_id";
            print $cmd , "\n";
            system($cmd) == 0 or die "Failed to execute: $cmd\n";  

            exit 0; # exit successfully 

        }else{
            # stop container
            $cmd = "$docker stop $container_id";
            print $cmd , "\n";
            system($cmd) == 0 or die "Failed to execute: $cmd\n";  

            # destroy container and image 
            $cmd = "$docker rm $container_id";
            print $cmd , "\n";
            system($cmd) == 0 or die "Failed to execute: $cmd\n";  

            $cmd = "$docker rmi $base_image_id";
            print $cmd , "\n";
            system($cmd) == 0 or die "Failed to execute: $cmd\n";  
            exit 1;
        }
    }else{
        # find latest container
        $cmd = "$docker run -d --name ${type}${epoch}-${git_commit} -p 2222:22 ${base_image_repo}:latest /usr/sbin/sshd -D";
        print $cmd, "\n";
        my $container_id = `$cmd`;
        if ($container_id eq ''){
            print "Please create base image first\n";
            exit 1;
        }

        # executing Ansible
        $cmd = "ANSIBLE_CONFIG=ansible/ansible.cfg $ansible -i 'localhost:2222,' ansible/${type}.yml";
        print $cmd, "\n";
        if (system($cmd) != 0 ){
            "Failed to execute: $cmd\n";  
            "Clean up container(id=$container_id)\n";
            $cmd = "$docker stop $container_id";
            system($cmd) == 0 or die "Failed to execute: $cmd\n";  
            $cmd = "$docker rm $container_id";
            system($cmd) == 0 or die "Failed to execute: $cmd\n";  
            exit 1;
        }

        chdir "tests/$type" or die "Can't cd to tests/${type}: $!\n";
        $cmd = "TARGET_HOST=localhost TARGET_PORT=2222 ./run.sh";
        print "chdir to tests/$type and execute: $cmd\n";
        if (system($cmd) == 0){
             # stop container
             $cmd = "$docker stop $container_id";
             print $cmd , "\n";
             system($cmd) == 0 or die "Failed to execute: $cmd\n";  
             exit 0;
        }else{
             # stop container
             $cmd = "$docker stop $container_id";
             print $cmd , "\n";
             system($cmd) == 0 or die "Failed to execute: $cmd\n";  

             # destroy container and image 
             $cmd = "$docker rm $container_id";
             print $cmd , "\n";
             system($cmd) == 0 or die "Failed to execute: $cmd\n";  
        }
        
    }
}

sub _run_test{
    my ($type, $ip, $port) = @_;
    my $dir = getcwd;

    print "Removing /var/lib/jenkins/.ssh/known_hosts\n";
    system "/bin/rm -f /var/lib/jenkins/.ssh/known_hosts";
    sleep(15);
 
    chdir "$dir/tests/$type" or die "Can't cd to tests/${type}: $!\n";
    my $cmd = "TARGET_HOST=$ip TARGET_PORT=$port ./run.sh";
    print "chdir to tests/$type and execute: $cmd\n";
    my $result = system($cmd);
    chdir $dir;
    return $result;
}


sub _create_do_image{
    my ($type, $name) = @_;

    #--------------------------------------------------
    # Get all sshkeys that are loaded on DisgitalOcean
    # These keys is to be used for VM's root
    #--------------------------------------------------
    my @ssh_key_ids;
    for my $line (split /\n/, `$doman --show_ssh_key`) {
        if ($line =~ /id:(\d+)/) {
            push @ssh_key_ids, $1;
        }
    }
    my $ssh_key_id = join ',', @ssh_key_ids; 
    print "SSH Key IDs: $ssh_key_id \n";

    my $cmd;
    my $line;

    print "Create image for $type...\n";
    my $packer_json_file = "$Bin/../packer/do-${type}.json";
    die "$packer_json_file is not found\n" if( ! -e $packer_json_file);

    # load size and region from the the packer json
    local $/;
    open( my $fh, "<", $packer_json_file) or die "can't open $packer_json_file: $!";
    my $json_text = <$fh>;
    my $ref = decode_json $json_text;
    my $size_id = $ref->{builders}[0]->{size_id};
    my $region_id = $ref->{builders}[0]->{region_id};
 
    $line = `$doman --show_my_image | grep $name`;
    if ($line =~ /id:(\d+)/){
        $cmd = "$doman --destroy_image -image_id $1";
        system($cmd) == 0 or die "Failed to execute: $cmd\n";
    }

    # create image now
    $cmd = "$packer build -var 'snapshot_name=$name' $packer_json_file";
    print "Execute: $cmd\n";
    system($cmd) == 0 or die "Failed to execute: $cmd\n";

    # get image_id
    $line = `$doman --show_my_image | grep $name`;
    $line =~ /id:(\S+)/;
    my $image_id = $1;
    unless (defined $image_id){
        print "ERROR: image ID is not found\n";
        exit 1;
    }
    # create droplet
    $cmd = "$doman --create_droplet -size_id $size_id -region_id $region_id -image_id $image_id -droplet_name $name -ssh_key_ids $ssh_key_id";
    print "Execute: $cmd\n";
    system($cmd) == 0 or die "Failed to execute: $cmd\n";

    # get IP and droplet ID
    $line = `$doman --show_droplet | grep $name`;
    $line =~ /ip:(\S+)/;
    my $ip = $1;
    die "ERROR: droplet IP is not found\n" unless (defined $ip);
    $line =~ /id:(\d+)/;
    my $droplet_id = $1;
    return ($ip, $droplet_id, $image_id);
}


