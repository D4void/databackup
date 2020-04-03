# databackup

A bash script to backup data and transfer the archive with ftp, ftpfs, sshfs or swift.

databackup  Backup files: zip it, encrypt it and upload it to Internet (ftp server, cloud...). Local copy is possible.

**USAGE**: 

`databackup [-e] [-h] [-i] [-l] [-m] [-mf] [-mode ftp,ftpfs,swift] [-r <n>] <backup name> [<files>] `

**OPTIONS**:

	-e encrypt backup file - check CIPHER and BKPPASS settings in .ini file

	-h this help

	-i check file integrity (md5sum)

	-l keep a local copy of the backup file - check LOCALBKPDIR settings in .ini file

	-m send backup log by email - check mail section in .ini file

	-mf send backup log by email only on failure

	-mode ftp (default): upload to ftp server (integrity check and backup files rotation is not possible)

		ftpfs : upload to ftp server by mounting it with fuse
		sshfs : upload to ssh server by mounting it with fuse
		swift : upload to openstack object storage

	-r <n> activate backup files rotation and keep only <n> backup. 
	   If <n> is not set, use default value set in .ini file.

**INI FILE:**

	.ini file is used to configure backups (directories, password, mail settings etc).

	For recurring backup, you can define a "\~/.<backup name>.ini" file.

	If "\~/.<backup name>.ini" doesn't exist, "\~/.databackup.ini" will be used.

	Files put in cli argument have the priority over files possibly defined in the .ini file.

**Example**:

`databackup.sh -e -i -r -l -mode swift MyFileBackup /home/user/MyFile`



