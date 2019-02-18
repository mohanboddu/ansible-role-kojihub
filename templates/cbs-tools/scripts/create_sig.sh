#!/bin/bash

usage()
{
cat << EOF
usage: $0 -d <distribution> -s <signame(s)> -t <tag(s)>

This script generate new build target in koji for SIGS.

OPTIONS:
   -a   ARCHES                   : Force arches e.g : "x86_64","aarch64 i686", etc...
   -b                            : Enable non public bootstrap repo (SCLO SIG only)
   -c   COLLECTION               : Enable collection in the buildroot e.g : mariadb100
   -d   DISTRIBUTION             : 5 6 7
   -p   SIG PROJECT NAME         : cloud6-<openstack>, sclo-<mariadb100>, etc...
   -r   SIG PROJECT RELEASE NAME : cloud6-openstack-<juno>
   -s   SIG NAME                 : cloud
   -t   DISTTAGS                 : "el7 el7.centos el7_0"
   -x                            : delete old -build tag and then recreate.
EOF
}

optiona=false
optionb=false
optiond=false
options=false
optiont=false
optionc=false
optionp=false
optionr=false
optionx=false

while getopts ":hxba:d:s:t:c:p:r:" OPTION
do
        case $OPTION in
        h)
             usage
             exit 0
             ;;
    a)
         optiona=true
         ARCHES="${OPTARG}"
         ;;
    b)
         optionb=true
         ;;
    d)
         optiond=true
         DISTS="${OPTARG}"
         ;;
    s)
         options=true
         SIGS="${OPTARG}"
         ;;
    r)
         optionr=true
         RELEASES="${OPTARG}"
         ;;
    p)
         optionp=true
         PROJECTS="${OPTARG}"
         ;;
    t)
         optiont=true
         TAGS="${OPTARG}"
         ;;
    c)
         optionc=true
         COLLECTIONS="${OPTARG}"
         ;;
    x)
         optionx=true
         ;;
        ?)
             exit 0
             ;;
        :)
             echo "Option -$OPTARG requires an argument."
             exit 1
             ;;
        esac
done

shift $(($OPTIND - 1))

if ! ( $optiond && $options && $optiont  )
then
    usage
    exit 0
fi

# Check if user is allowed to send command to koji and has 'admin' permission
KOJI=`which koji`
PERMS=`$KOJI list-permissions --mine`
ADMIN=false
CONFIG_PATH="$(dirname $BASH_SOURCE)/sigs"

for P in $PERMS
do
    [[ $P == 'admin' ]] && ADMIN=true && break
done

if [ "$ADMIN" != true ]
then
    echo "[ERROR] Koji misconfigure/missing admin privilege for creating SIG tags"
    exit 1
fi

for DIST in $DISTS
do

    case $DIST in
        5) echo "* Checking distribution el$DIST configuration..."; ( ! $optiona ) && ARCHES="i386 x86_64"; DEFAULT_DISTTAG="el5"
        ;;
        6) echo "* Checking distribution el$DIST configuration...";  ( ! $optiona ) &&  ARCHES="i686 x86_64"; DEFAULT_DISTTAG="el6"
        ;;
        7) echo "* Checking distribution el$DIST configuration...";  ( ! $optiona ) && ARCHES="x86_64"; DEFAULT_DISTTAG="el7.centos"
        ;;
        *) echo "It seems your distribution el${DIST} is unsupported" && continue
        ;;
    esac

    $KOJI list-tags | grep buildsys${DIST} &> /dev/null
    [ $? -gt 0 ] && echo " -> [ERROR] Something is wrong buildsys${DIST} tag not found." && continue

    $KOJI list-external-repos | grep ^centos${DIST}-extras &> /dev/null
    [ $? -gt 0 ] && echo " -> [ERROR] centos${DIST}-extras external repo not configured in koji." && continue

    $KOJI list-external-repos | grep ^centos${DIST}-os &> /dev/null
    [ $? -gt 0 ] && echo " -> [ERROR] centos${DIST}-os external repo not configured in koji." && continue

    $KOJI list-external-repos | grep ^centos${DIST}-updates &> /dev/null
    [ $? -gt 0 ] && echo " -> [ERROR] centos${DIST}-updates external repo not configured in koji." && continue

    for SIG in $SIGS
    do
        # reset values from SIG configuation file
        BUILDROOT_DEFAULT=""

        echo " -> Checking $SIG config..."
        $KOJI add-user $SIG &> /dev/null
        [ $? -eq 0 ] && echo "Creating user : ${SIG}" && $KOJI grant-permission --new build-${SIG} $SIG
        SIGNAME="${SIG}"
        SIG="${SIG}${DIST}"
        # Check for SIG-common and create it if not present.
        # $KOJI list-tags | grep $SIG-common-candidate &> /dev/null
        for PROJECT in $PROJECTS
        do
            P_SIG="${SIG}-${PROJECT}"
            # Add sig project options here FIXME add a command line option for oneshot buildroot fixes.
            case ${PROJECT} in
                openstack)
                    echo "Reading ${PROJECT} additional configs..."
                    BUILDROOT_PKGS_EXTRAS="openstack-macros"
                    ;;
                *)
                    BUILDROOT_PKGS_EXTRAS=""
                ;;
            esac

            # Check for -common
            #$KOJI list-tags | grep $P_SIG-common-candidate &> /dev/null
            #if [ $? -gt 0 ]
            #then
            #   echo "Creating tag  : ${P_SIG}-common"
            #   $KOJI add-tag $P_SIG-common-candidate
            #
            #fi
            for RELEASE in $RELEASES
            do
                R_SIG="${P_SIG}-${RELEASE}"
                $KOJI list-tags | grep $R_SIG-candidate &> /dev/null
                [ $? -gt 0 ] && echo "Creating tag  : ${R_SIG}-candidate" && $KOJI add-tag $R_SIG-candidate && $KOJI edit-tag $R_SIG-candidate --perm=build-${SIGNAME}
                $KOJI list-tags | grep $R_SIG-testing &> /dev/null
                [ $? -gt 0 ] && echo "Creating tag  : ${R_SIG}-testing" && $KOJI add-tag $R_SIG-testing && $KOJI edit-tag $R_SIG-testing --perm=build-${SIGNAME}
                $KOJI list-tags | grep $R_SIG-release &> /dev/null
                [ $? -gt 0 ] && echo "Creating tag  : ${R_SIG}-release" && $KOJI add-tag $R_SIG-release && $KOJI edit-tag $R_SIG-release --perm=build-${SIGNAME}

                for TAG in $TAGS
                do
                    # Add collection support abuse TAG variable
                    REALTAG=$TAG
                    if ( $optionc )
                    then
                        # Abandon collection in the name for the tag, not pratical
                        # TAG="$TAG-$COLLECTIONS"
                        TAG="$TAG"
                    fi
                    $KOJI list-tags | grep $R_SIG-$TAG-build &> /dev/null
                    if [ $? -eq 0 ]
                    then
                        if ( $optionx )
                        then
                            echo " -> deleting buildroot $R_SIG-$TAG-build"
                            $KOJI remove-tag $R_SIG-$TAG-build
                        else
                            echo " -> $R_SIG-$TAG-build tag already exists. skipping." && continue
                        fi
                    fi
                    echo " -> creating $R_SIG-$TAG"
                    $KOJI add-tag --arches "$ARCHES" $R_SIG-$TAG-build
                    $KOJI add-target $R_SIG-$TAG $R_SIG-$TAG-build $R_SIG-candidate
                    # For external repo priorites are increased by 5, Priority 5
                    if [ "x$DIST" == "x7" ]
                    then
                        $KOJI add-external-repo --tag=$R_SIG-$TAG-build centos${DIST}-cr
                    fi
                    $KOJI add-external-repo --tag=$R_SIG-$TAG-build centos${DIST}-extras
                    $KOJI add-external-repo --tag=$R_SIG-$TAG-build centos${DIST}-updates
                    $KOJI add-external-repo --tag=$R_SIG-$TAG-build centos${DIST}-os
                    # START bootstrap
                    if ( $optionb )
                                        then
                        # START bootstrap for sclo
                        if [ "x${SIGNAME}" == "xsclo" ]
                                                then
                            # Priority 15
                            $KOJI add-external-repo --tag=$R_SIG-$TAG-build sclo${DIST}-bootstrap
                        fi
                        # END bootstrap for scl
                        # Other repo can be added here if needed in the future
                        # if [ "x${SIGNAME}" == "xABC" ]
                        # Let's use $SIGNAME$DIST-bootstrap to be consistent
                    fi
                    # END bootstrap
                    $KOJI add-group $R_SIG-$TAG-build build
                    $KOJI add-group $R_SIG-$TAG-build srpm-build
                    # Add <collection>-build to the buildroot if collection enabled
                    if [ -f $CONFIG_PATH/$SIGNAME/$PROJECT/config.sh ]
                    then
                        echo "Using specific $SIGNAME/$PROJECT options: "
                        echo "###"
                        cat $CONFIG_PATH/$SIGNAME/$PROJECT/config.sh
                        echo "###"
                        source $CONFIG_PATH/$SIGNAME/$PROJECT/config.sh
                    else
                        BUILDROOT_DEFAULT="curl bash bzip2 coreutils cpio diffutils redhat-release findutils gawk gcc gcc-c++ grep gzip info make patch redhat-rpm-config rpm-build sed shadow-utils tar unzip util-linux-ng which buildsys-tools tar"
                                                COMMON_INHERITANCE=true
                    fi
                    if ( $optionc )
                    then
                        $KOJI add-group-pkg $R_SIG-$TAG-build build $BUILDROOT_DEFAULT buildsys-macros-$REALTAG $COLLECTIONS-build scl-utils-build
                        $KOJI add-group-pkg $R_SIG-$TAG-build srpm-build $BUILDROOT_DEFAULT buildsys-macros-$REALTAG $COLLECTIONS-build scl-utils-build
                    else
                        $KOJI add-group-pkg $R_SIG-$TAG-build build $BUILDROOT_DEFAULT buildsys-macros-$REALTAG $BUILDROOT_PKGS_EXTRAS
                        $KOJI add-group-pkg $R_SIG-$TAG-build srpm-build $BUILDROOT_DEFAULT buildsys-macros-$REALTAG $BUILDROOT_PKGS_EXTRAS
                    fi
                    $KOJI add-tag-inheritance --priority 5 $R_SIG-$TAG-build buildsys${DIST}
                    $KOJI add-tag-inheritance --priority 10 $R_SIG-$TAG-build $R_SIG-candidate
                    # If -common exists for the project add it
                    if [ "x$RELEASE" != "xcommon" ] && [ "x$COMMON_INHERITANCE" != "xfalse" ]
                    then
                        $KOJI list-tags | grep $P_SIG-common-candidate &> /dev/null
                                                [ $? -eq 0 ] && echo "Adding $P_SIG-common-candidate as inheritance" && $KOJI add-tag-inheritance --priority 15 $R_SIG-$TAG-build $P_SIG-common-candidate
                    fi
                    # Add SIG -common if it exists
                    if [ "x$COMMON_INHERITANCE" != "xfalse" ]
                    then
                        $KOJI list-tags | grep $SIG-common-candidate &> /dev/null
                        [ $? -eq 0 ] && echo "Adding $SIG-common-candidate as inheritance" && $KOJI add-tag-inheritance --priority 20 $R_SIG-$TAG-build $SIG-common-candidate
                    fi
                    # Check if disttag has corresponding buildsys-macros-disttag
                    $KOJI list-tagged buildsys${DIST} | grep buildsys-macros-$REALTAG &> /dev/null
                    if [ $? -gt 0 ]
                    then
                        if [ "x$REALTAG" != "x$DEFAULT_DISTTAG" ]
                        then
                            echo " -> [WARN] buildsys-macros-$REALTAG rpm not found. Please build it within koji on target buildsys${DIST}"
                            #TODO ; generate spec file from template for overriding macros
                            [ -f $PWD/etc/buildsys.spec.template ] && echo " -> Generating buildsys-macros-$TAG.spec"
                        fi
                    fi
                done
            done
        done
    done
done