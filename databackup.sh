#!/bin/bash
########################################################################################################################
# Script databackup.sh
# Backup data files
# Backup are zipped and can be encrypted (AES)
# Possible modes are: ftp, ftpfs, sshfs, swift
#
#    Copyright (C) 2020 - D4void - d4void@m4he.fr
#    https://github.com/D4void/databackup
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
########################################################################################################################
# Dependencies:
#  - Require:  GnuPG, Curlftpfs, Fuse sshfs, Swift
#  - Optional: Swaks (for email) if MTA like exim is not available on the system
########################################################################################################################
# Information
# For root privilege and to backup root files:
#   visudo
#   add: user ALL=(ALL) NOPASSWD: /usr/bin/zip
#   In the ini files, PRIV=TRUE
#
########################################################################################################################
# 15/03/27 - v1.0 - Creation of databackup.sh
# 15/04/16 - v1.1 - End of dev and test
# 15/10/18 - v1.2 - Adding retry with fuse mount when error happened
# 15/12/29 - v1.3 - Easiest way to deal with files list and make array (arguments and ini files)
# 16/01/26 - v1.4 - ini settings with '=' and not ' = '
# 16/06/17 - v1.5 - Adding sshfs option
# 20/01/02 - v1.6 - Modifying gpg with --batch option
# 20/03/12 - v1.7 - Remove hubicfuse option. Add openstack swift support. Code review.
########################################################################################################################


ver="1.7"

BANNERINIT="=======================- DATABACKUP LOG -========================="
BANNEREND="==================- END of DATABACKUP LOG -======================="

DEFAULTINI=".databackup.ini"
NBMOUNTRETRY=3

############################################################
# FUNCTIONS
############################################################


__help()
{
	echo
	cat <<END_HELP
databackup -- Backup files: zip it, encrypt it and upload it to Internet (ftp server, cloud...)
              Local copy is possible.

USAGE: databackup [-e] [-h] [-i] [-l] [-m] [-mode ftp,ftpfs,swift] [-r <n>] <backup name> [<files>]

OPTIONS:
	-e encrypt backup file - check CIPHER and BKPPASS settings in .ini file
	-h this help
	-i check file integrity (md5sum)
	-l keep a local copy of the backup file - check LOCALBKPDIR settings in .ini file
	-m send backup log by email - check mail section in .ini file
	-mode ftp (default): upload to ftp server (integrity check and backup files rotation is not possible)
	      ftpfs : upload to ftp server by mounting it with fuse
              sshfs : upload to ssh server by mounting it with fuse
	      swift : upload to openstack object storage
        -r <n> activate backup files rotation and keep only <n> backup. If <n> is not set, use default value set in .ini file.

INI FILE:
	.ini file is used to configure backups (directories, password, mail settings etc).
	For recurring backup, you can define a "~/.<backup name>.ini" file.
	If "~/.<backup name>.ini" doesn't exist, "~/.databackup.ini" will be used.
	Files put in cli argument have the priority over files possibly defined in the .ini file.


version $ver

databackup.sh  Copyright (C) 2020 - D4void
    This program comes with ABSOLUTELY NO WARRANTY, check LICENSE file for details.
    This is free software, and you are welcome to redistribute it
    under certain conditions, check LICENSE file for details.

END_HELP

exit 0
}

__read_ini () {
	# function to read ini files: search a pattern put in arg and print it
	echo $(awk -v patt="$1" -F "=" '{if (! ($0 ~ /^;/) && $0 ~ patt ) print $2}' $INIFILE)
}

__init_settings() {
	# function to initialise required variables. Values are parsed in the .ini files
	INIFILE="$HOME/.$BKPNAME.ini"
	if [[ ! -f "$INIFILE" ]]; then
		echo "$INIFILE doesn't exist. Using $HOME/$DEFAULTINI"
		INIFILE="$HOME/$DEFAULTINI"
		if [[ ! -f "$INIFILE" ]]; then
			echo "Error: $INIFILE doesn't exist. Can't init settings."; exit 1
		fi
	fi

	# Server and credentials
	BKPSERVER=$(__read_ini "BKPSERVER")
	USER=$(__read_ini "USER")
	PASSWD=$(__read_ini "PASSWD")

	# Swift openrc file
	SWIFTOPENRC=$(__read_ini "SWIFTOPENRC")
	if [[ ! -z "$SWIFTOPENRC" ]]; then
		if [[ ! -f "$SWIFTOPENRC" ]]; then
			echo "Error: Swift openrc file $SWIFTOPENRC not found. Check settings."; exit 1
		fi
	fi

	# OVH swift header for Public Cloud Archive 
	SWIFTHEADER=$(__read_ini "SWIFTHEADER")

	# Privilege
	PRIV=$(__read_ini "PRIV")
	if [[ -z "$PRIV" ]]; then
		PRIV=false
	fi

	# Directories
	if $LOCAL; then
		LOCALBKPDIR=$(__read_ini "LOCALBKPDIR")
		if [[ ! -d "$LOCALBKPDIR" ]]; then
			echo "Error: $LOCALBKPDIR  is not a directory or doesn't exist."; exit 1
		elif [[ ! -w "$LOCALBKPDIR" ]]; then
			echo "Error: No write access to $LOCALBKPDIR."; exit 1
		fi
	fi

	RMTBKPDIR=$(__read_ini "RMTBKPDIR")
	FSMOUNTDIR=$(__read_ini "FSMOUNTDIR")
	BKPSRVDIR=$(__read_ini "BKPSRVDIR")

	# Retention by default (number of backup to keep if option is activated)
	if [[ -z "$RETENTION" ]]; then
		RETENTION=$(__read_ini "RETENTION")
	fi

	# Mail settings
	MTA=$(__read_ini "MTA")
	MAILSERVER=$(__read_ini "MAILSERVER")
	MAILPORT=$(__read_ini "MAILPORT")
	MAILLOGIN=$(__read_ini "MAILLOGIN")
	MAILPASS=$(__read_ini "MAILPASS")
	FROM=$(__read_ini "FROM")
	TO=$(__read_ini "TO")

	# Encryption
	CIPHER=$(__read_ini "CIPHER")
	BKPPASS=$(__read_ini "BKPPASS")

	#FILES TO BACKUP - Create an array
	# if no files are put in cli arguments, reading files to backup in the .ini file
	if [[ ${#FILETAB[@]} -eq 0 ]]; then
		IFS=':' read -ra FILETAB <<< $(awk -v patt="FILE" -F "=" 'BEGIN {ORS=":"} {if (! ($0 ~ /^;/) && $0 ~ patt ) print $2}' $INIFILE)
		if [[ ${#FILETAB[@]} -eq 0 ]]; then
			echo "Error: No files to backup specified in cli or .ini file..."; exit 1
		fi
	fi
}

__error() {
	__log "$1"
	__log "Backup failed!  :'("
	if [[ -f "$ARCHFILE" ]]; then
		__log "Deleting $ARCHFILE"
		rm "$ARCHFILE" 2>&1 | tee -a $LOGFILE
	fi
	__terminate
	set +o pipefail
	exit "$2"
}

__log() {
	echo $(date '+%Y/%m/%d-%Hh%Mm%Ss:') "$1" | tee -a $LOGFILE
}

__compress_encrypt() {
	__log "Files to backup: $(echo "${FILETAB[@]}") "
	
	ARCHFILE="$FILE"
	if $PRIV; then
		__log "Compressing files with root privilege in $FILE..."
		sudo zip -r "$ARCHFILE" "${FILETAB[@]}" 2>&1 | tee -a $LOGFILE
	else
		__log "Compressing files in $FILE..."
		zip -r "$ARCHFILE" "${FILETAB[@]}" 2>&1 | tee -a $LOGFILE
	fi
	if [[ $? -eq 0 ]]; then
		if $ENCRYPT; then
			ARCHFILE="$FILEC"
			sleep 1
			__log "Encrypting in $FILEC"
			gpg -c --batch --passphrase "$BKPPASS" --s2k-cipher-algo $CIPHER -o "$ARCHFILE" "$FILE" 2>&1 | tee -a $LOGFILE
			if [[ $? -ne 0 ]]; then
				__error "Error encrypting archive file. Stopping..." 1
			fi
			__log "Deleting $FILE"
			rm -f "$FILE" 2>&1 | tee -a $LOGFILE
			sleep 1
		fi
	else
		__error "Error creating archive file. Stopping..." 1
	fi
}

__mountfs() {
        __log "Verifying if server is mounted ($MODE) ..."
        mount | grep $(echo "$FSMOUNTDIR" | sed 's/\/$//g') >/dev/null 2>/dev/null
        if [[ $? -ne 0 ]]; then
                __log "Mounting server $BKPSERVER:$BKPSRVDIR to $FSMOUNTDIR."
		mountstatus=1
                i=0
		sec=0
                while [ $mountstatus -ne 0  ] && [ $i -lt $NBMOUNTRETRY ] ; do
                        sleep $sec
			if [[ $MODE == "ftpfs" ]]; then
				curlftpfs -o direct_io,user="$USER:$PASSWD",uid=$(id -u),gid=$(id -g) "$BKPSERVER":"$BKPSRVDIR" "$FSMOUNTDIR" 2>&1 | tee -a $LOGFILE
			elif [[ $MODE == "sshfs" ]]; then
                        	echo "$PASSWD" | sshfs "$USER"@"$BKPSERVER":"$BKPSRVDIR" "$FSMOUNTDIR" -o direct_io,password_stdin,uid=$(id -u),gid=$(id -g) 2>&1 | tee -a $LOGFILE
			fi
                        mountstatus=$?
			if [[ $mountstatus -ne 0 ]]; then
				let i=i+1
				let sec=30*i
				if [[ $i -ne $NBMOUNTRETRY ]]; then
					__log "Mount failed. Retry in $sec s..."
				else
					__error "Mount error. Check settings or server access. Stopping..." 1	
				fi
			fi
                done                
        else
                __log "Server is already mounted."
        fi
}

__umountfs() {
	__log "Unmounting server."
	fusermount -u "$FSMOUNTDIR" 2>&1 | tee -a $LOGFILE
	if [[ $? -ne 0 ]]; then
		__log "Umount error."
        fi
}

__check_bkpdir() {
	if [[ ! -d "$1" ]]; then
		__log "$1 doesn't exist. Creating it"
		mkdir -p "$1" 2>&1 | tee -a $LOGFILE
		if [[ $? -ne 0 ]]; then
			__error "Error creating the directory." 1
		fi
	fi
}

__local_copy() {
	DSTLBKPDIR=$(echo "$LOCALBKPDIR/$BKPNAME" | tr -s / /)
	__log "Local backup enabled: copying $ARCHFILE to $DSTLBKPDIR"
	__check_bkpdir "$DSTLBKPDIR"
	cp "$ARCHFILE" "$DSTLBKPDIR" 2>&1 | tee -a $LOGFILE
	if [[ ! $? -eq 0 ]]; then
		__log "Warning: error while copying $ARCHFILE to $DSTLBKPDIR"
	fi
}

__transfer_ftp() {
	# no directory check here. Be sure $RMTBKPDIR exists.
	DSTBKPDIR=$(echo "$RMTBKPDIR/$BKPNAME" | tr -s / /)
	__log "Uploading $ARCHFILE to ftp server $USER@$BKPSERVER in $DSTBKPDIR..."
	FTPLOG="ftplog.log"
        echo "
        user $USER $PASSWD
	cd "$RMTBKPDIR"
	mkdir "$BKPNAME"
	cd "$BKPNAME"
        bin
        put "$ARCHFILE"
        bye
        " | ftp -p -n -i -v "$BKPSERVER" > $FTPLOG

	__log "$(cat $FTPLOG)"
	if ! fgrep "226 " $FTPLOG >/dev/null 2>&1 ;then
		rm $FTPLOG
       	__error "Error during ftp transfer. Stopping..." 1
	fi
	rm $FTPLOG
	if $LOCAL; then
		__local_copy
	fi
}

__transfer_swift() {
	SWIFT=/usr/local/bin/swift
	if [[ ! -z "$SWIFTOPENRC" ]]; then
		source "$SWIFTOPENRC"
	else
		__error "Error: Swift openrc file is not set. Check settings." 1
	fi

	$SWIFT list >/dev/null 2>&1
	if [[ $? -ne 0 ]]; then
		__error "Error: Swift access failed. Check settings." 1
	fi

	$SWIFT list "$BKPNAME" >/dev/null 2>&1
	if [[ $? -ne 0 ]]; then
		__log "Container $BKPNAME doesn't exist. Creating it"
		if [[ -z "$SWIFTHEADER" ]]; then
 			$SWIFT post "$BKPNAME" 2>&1 | tee -a $LOGFILE
		else
			$SWIFT post --header "$SWIFTHEADER" "$BKPNAME" 2>&1 | tee -a $LOGFILE
		fi
	fi
        if [[ $? -ne 0 ]]; then
        	__error "Error creating the container." 1
        fi
	
	__log "Uploading $ARCHFILE to the openstack container $BKPNAME"
	$SWIFT upload "$BKPNAME" "$ARCHFILE" 2>&1 | tee -a $LOGFILE
	if [[ $? -ne 0 ]]; then
                __error "Error sending file to the container $BKPNAME." 1
        fi

	if $LOCAL; then
                __local_copy
        fi
	if $INTEGRITY; then
		__integrity_checkup
	fi
	if $ROTATE; then
		__backup_rotate
	fi
}

__copyfs() {
	DSTBKPDIR=$(echo "$FSMOUNTDIR/$RMTBKPDIR/$BKPNAME" | tr -s / /)
	__check_bkpdir "$DSTBKPDIR"
	__log "Uploading $ARCHFILE to server $USER@$BKPSERVER via $DSTBKPDIR..."
	cp "$ARCHFILE" "$DSTBKPDIR" 2>&1 | tee -a $LOGFILE
	if [[ $? -ne 0 ]]; then
		__error "Error during copy to server. Stopping..." 1
	fi
	if $LOCAL; then
		__local_copy
	fi
	if $INTEGRITY; then
		__integrity_checkup
	fi
	if $ROTATE; then
        	__backup_rotate
        fi
}

__md5sum () {
	md5sum "$1" | cut -f 1 -d ' '
	return $?
}

__integrity_checkup() {
	local ERROR=false
	MD5SRC=$(__md5sum "$ARCHFILE")
	if [[ $? -ne 0 ]]; then
		ERROR=true
		__log "Warning: local backup md5sum failed."
	else
		__log "Local backup file md5sum: $MD5SRC"
	fi

	if [[ $MODE == "swift" ]]; then
		MD5DST=$($SWIFT stat "$BKPNAME" "$ARCHFILE" | grep ETag: | cut -d':' -f2 | tr -d ' ')
	else
		MD5DST=$(__md5sum $(echo "$DSTBKPDIR/$ARCHFILE" | tr -s / /) )
	fi
	if [[ $? -ne 0 ]]; then
		ERROR=true
		__log "Warning: remote backup file md5sum failed."
	else
		__log "Remote backup file md5sum: $MD5DST"
	fi
	if ! $ERROR; then
		if [[ $MD5DST = $MD5SRC ]]; then
			__log "Integrity ok."
		else
			__error "Error: remote backup file seems to be altered." 1
		fi
	else
		__log "Warning: Integrity checkup failed"
	fi
}

__backup_rotate() {
	if $LOCAL; then
		__log "Backup rotation enabled: deleting old local backup files (keeping only $RETENTION backup)"
		find "$DSTLBKPDIR" -type f -name "$BKPNAME*" | sort | head --lines=-$RETENTION | xargs --no-run-if-empty rm -f 2>&1 | tee -a $LOGFILE
	fi

	__log "Backup rotation enabled: deleting old remote backup files (keeping only $RETENTION backup)"	
	if [[ $MODE == "swift" ]]; then
		$SWIFT list "$BKPNAME" --prefix "$BKPNAME" | head --lines -$RETENTION | xargs --no-run-if-empty -d '\n' $SWIFT delete "$BKPNAME" 2>&1 | tee -a $LOGFILE
	else
		find "$DSTBKPDIR" -type f -name "$BKPNAME*" | sort | head --lines=-$RETENTION | xargs --no-run-if-empty rm -f 2>&1 | tee -a $LOGFILE
	fi
}

__send_mail() {
	if $SUCCESS; then
		SUBJECT="Backup Log: Success ($BKPNAME)"
	else
		SUBJECT="Backup Log: Fail! ($BKPNAME)"
	fi
	if $MTA; then
		cat "$LOGFILE" | mail -s "$SUBJECT" $TO
	else
		swaks -S -s $MAILSERVER -p $MAILPORT --auth CRAM-MD5 --tls -a -au $MAILLOGIN -ap $MAILPASS -t $TO -f $FROM --header "Subject: $SUBJECT" --body $LOGFILE
		if [[ $? -ne 0 ]]; then
			__log "Error with swaks while sending log by email."
			exit 1
		fi
	fi
}

__isNum() {
	[ $1 -eq 0 ] 2>/dev/null;[ $? -eq 0 -o $? -eq 1 ] && return 0 || return 1
}

__terminate() {
	if $MAIL; then
		if $MTA; then
			__log "Sending an email with MTA."
		else
			__log "Sending an email with swaks."
		fi
		echo -e "\n$BANNEREND\n" | tee -a $LOGFILE
		__send_mail
	else
		echo -e "\n$BANNEREND\n" | tee -a $LOGFILE
	fi
}

############################################################
# MAIN
############################################################

# Default transfer mode if not specified in cli argument
MODE=ftp
# Init variables
ROOTBKP=false
LOCAL=false
ENCRYPT=false
MAIL=false
ROTATE=false
INTEGRITY=false
SUCCESS=false

while [ -n "$1" ]; do
case $1 in
    -e) ENCRYPT=true;shift;;
    -h) __help;shift;;
    -i) INTEGRITY=true;shift;;
    -l) LOCAL=true;shift;;
    -m) MAIL=true;shift;;
    -mode) shift;MODE=$1;shift;;
    -r) ROTATE=true;shift;__isNum $1;if [[ $? -eq 0 ]]; then RETENTION=$1;shift;fi;;
    --) break;;
    -*) echo "Error: No such option $1. -h for help"; exit 1;;
    *) BKPNAME="$1";shift;FILETAB=( "$@" );break;;
esac
done

if [[ -z "$BKPNAME" ]]; then
	echo "Error: no backup name specified. See -h for help."; exit 1
fi

# Init settings
__init_settings

# Filenames definition
FDATE=$(date '+%Y_%m_%d-%Hh%M')
FILE="$BKPNAME-$(date '+%Y_%m_%d-%Hh%M').zip"
FILEC="$FILE.gpg"
LOGFILE="$HOME/.$BKPNAME.log"

set -o pipefail 1
echo -e "\n$BANNERINIT\n" | tee $LOGFILE
__log "Launching backup."

# Compress and encrypt
__compress_encrypt

# Upload backup file on internet
case $MODE in
	ftp) __transfer_ftp;;
	ftpfs | sshfs) __mountfs; __copyfs; sleep 5; __umountfs;;
	swift) __transfer_swift;;
	*) __log "Wrong backup mode '$MODE'. Using default mode. "; __transfer_ftp;;
esac
sleep 1

__log "Deleting temp $ARCHFILE"
rm "$ARCHFILE" 2>&1 | tee -a $LOGFILE

__log "Backup successfull *_*"
SUCCESS=true
__terminate

set +o pipefail
exit 0
