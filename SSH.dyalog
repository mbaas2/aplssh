﻿⍝∇:require =/CInterop.dyalog
⍝∇:require =/Sock.dyalog

:Namespace SSH
    ⍝ APL bindings for the libssh2 library

    SSH_ERR←801 ⍝ signaled when there's something wrong with the SSH library

    init←0
    ∇ Init;r
        →init/0 ⍝ don't initialize twice

        ⍝ Make sure the socket library is initialized
        #.Sock.Init

        ⍝ load the library functions
        C.LoadLib

        ⍝ run the libssh2 initialization
        r←C.libssh2_init 0

        ⍝ signal an error if it did not work
        ⎕SIGNAL(r≠0)⊂('EN'SSH_ERR)('Message' (⍕r))

        init←1 
    ∇

    ⍝ An SSH session
    :Class Session
        :Field Private Shared S ⍝ shorthand for the namespace
        :Field Private Shared C ⍝ shorthand for all the C functions
        :Field Private session←0
        :Field Private socket←⍬ ⍝ socket associated with the session, if there is one

        defaults←{
            (≢⍺)↑⍵,(≢⍵)↓⍺
        }
        
        ∇r←Ref
            :Access Public
            r←session
        ∇
        
        ∇destroy
            :Implements Destructor
            →(session=0)/0
            Disconnect S.SSH_DISCONNECT_BY_APPLICATION 'Session destructor called'
        ∇
        
        ∇Disconnect args;reas;desc;lang;localsess
            :Access Public
            →(session=0)/0
            reas desc lang←(S.SSH_DISCONNECT_BY_APPLICATION '' '')defaults args
            localsess←session
            session←0
            {}C.libssh2_session_disconnect_ex localsess reas desc lang
            {}C.libssh2_session_free localsess
        ∇
        
        ⍝ common initialization routine
        ∇_init_common
            ⍝ put the namespaces in the shorthand fields
            S ← #.SSH
            C ← #.SSH.C

            ⍝ is the SSH lib initialized yet?
            :If ~#.SSH.init ⋄ #.SSH.Init ⋄ :EndIf

            ⍝ make a session
            ⍝ we don't do callbacks into APL, because APL doesn't do callbacks into APL...
            session←C.libssh2_session_init_ex 0 0 0 0
            ⎕SIGNAL(session=0)/⊂('EN'S.SSH_ERR)('Message' 'libssh2 initialization failed')
        ∇

        ⍝ Initialize the session
        ∇init
            :Implements Constructor
            :Access Public
            _init_common
        ∇

        ⍝ Utility initializer, which does socket creation, connection, and handshake
        ⍝ all at once (if you don't need anything special)
        ∇init_connect (host port);sock
            :Implements Constructor
            :Access Public
            _init_common ⍝ initialization
            sock←⎕NEW #.Sock.Socket #.Sock.Cnst.SOCK_STREAM
            sock.Connect (host port)
            Handshake sock
        ∇

        ⍝ Handshake. 'sock' should be a socket object
        ∇Handshake sock;r
            :Access Public
            r←C.libssh2_session_handshake session sock.FD
            ⎕SIGNAL(r≠0)/⊂('EN'S.SSH_ERR)('Message' ('Handshake failed:', ⍕r))
            socket←sock
        ∇

        ⍝ Get the hostkey hash, as a byte vector
        ⍝ Type may be 'MD5' or 'SHA1' (or, of course, LIBSSH2_HOSTKEY_HASH_...)
        ∇hash←HostkeyHash type;blk;sz;ptr
            :Access Public
            sz←0

            ⍝ support string input
            :If 'md5'≡819⌶type  ⋄ type←S.HOSTKEY_HASH_MD5  ⋄ :EndIf
            :If 'sha1'≡819⌶type ⋄ type←S.HOSTKEY_HASH_SHA1 ⋄ :EndIf

            ⍝ get the size (as defined in the documentation)
            :If type≡S.HOSTKEY_HASH_MD5  ⋄ sz←16 ⋄ :EndIf
            :If type≡S.HOSTKEY_HASH_SHA1 ⋄ sz←20 ⋄ :EndIf

            ⍝ if the size is still unknown, then the hash type was invalid
            ⎕SIGNAL(sz=0)/⊂('EN'11)('Message' ('Invalid hash type: ',∊⍕type))

            ⍝ ask for the hash type
            ptr←C.libssh2_hostkey_hash session type
            ⎕SIGNAL(ptr=0)/⊂('EN'S.SSH_ERR)('Message' ('Hostkey hash not available.'))

            ⍝ reserve some memory to store the hash type
            blk←⎕NEW #.CInterop.DataBlock (sz/0)
            blk.Load ptr sz
            hash←blk.Data
        ∇

        ⍝ Get a list of supported authentication methods.
        ⍝ libssh2 returns this as a comma-delineated string, this being APL
        ⍝ we can return a string vector instead.
        ⍝ Internally, this works by trying to authenticate with SSH_USERAUTH_NONE,
        ⍝ might you find a server that supports this, we won't get a list back.
        ⍝
        ⍝ This function will check if that authentication succeeded, and will then
        ⍝ return the empty vector. If the lack of result was due to an error, an error
        ⍝ will be signaled.
        ∇list←UserauthList username;ptr;str
            :Access Public

            ptr←C.libssh2_userauth_list session username (≢username)

            :If ptr=0
                ⍝ did the "authentication" succeed?
                :If Authenticated
                    ⍝ such security
                    list←⍬
                :Else
                    ⍝ this really is an error
                    ⎕SIGNAL⊂('EN'S.SSH_ERR)('Message' 'libssh2_userauth_list failed')
                :EndIf
            :Else
                ⍝ we have a pointer to a comma-delimited string
                str←#.CInterop.ReadCStr ptr
                list←(str≠',')⊆str
            :EndIf
        ∇
        
        ⍝Try to authenticate by password
        ∇Userauth_Password (name password);r
            :Access Public
            r←C.libssh2_userauth_password_ex session name (≢name) password (≢password) 0
            ⎕SIGNAL (r≠0)/⊂('EN'S.SSH_ERR)('Message' (⍕r))
        ∇
        
        ⍝ Try to authenticate by public key
        ∇Userauth_Publickey (name pubkey privkey pass);r;pkblk;pkptr
            :Access Public
            
            ⍝ 'pubkey' may be zero, and must therefore be passed in as a pointer
            pkptr←0
            :If 0≠≢pubkey
                ⍝ a public key is given, so we need to turn it into a C string
                pkblk←⎕NEW #.CInterop.DataBlock (⎕UCS pubkey)
                pkptr←pkblk.Ref
            :EndIf
            
            r←C.libssh2_userauth_publickey_fromfile_ex session name (≢name) pkptr privkey pass
            ⎕SIGNAL (r≠0)/⊂('EN'S.SSH_ERR)('Message' (⍕r))
        ∇
        
        ⍝ See if this session is authenticated. Returns a boolean.
        ∇r←Authenticated
            :Access Public
            r←C.libssh2_userauth_authenticated session
        ∇
        
        ∇r←GetBlocking
            :Access Public
            r←C.libssh2_get_blocking session
        ∇
        
        ∇SetBlocking b
            :Access Public
            {}C.libssh2_set_blocking session b
        ∇
        
        ⍝ Make a new channel 
        ∇ch←Channel_Direct_TCPIP (desthost destport shost sport)
            :Access Public
            ch←⎕NEW S.Channel (⎕THIS desthost destport shost sport)
        ∇
    :EndClass
    
    ⍝ these are instantiated by the Session class
    :Class Channel
        :Field Private ptr←0
        :Field Private S
        :Field Private C
        :Field Private session
        
        ∇r←Ref
            :Access Public
            r←ptr
        ∇
        
        ∇init sess
            :Access Public
            :Implements Constructor
            
            S←#.SSH
            C←#.SSH.C
            session←sess
        ∇
        
        ∇destroy
            :Access Private
            :Implements Destructor
            Close
        ∇
        
        ∇Close;localptr
            :Access Public
            →(ptr=0)/0
            localptr←ptr
            ptr←0
            {}C.libssh2_channel_free ptr
        ∇
        
        ⍝ this is ugly, but I can't guarantee it's initialized otherwise
        ⍝ (no abstract classes apparently)
        ∇Check
            ⎕SIGNAL(ptr=0)/⊂('EN'16)('Message' 'Channel not initialized.')
        ∇
        
        ⍝ ERROR_EAGAIN sets 'again', anything else is considered an error
        ∇(again r)←{stream} Write data;rr
            :Access Public
            Check
            :If 0=⎕NC'stream' ⋄ stream←0 ⋄ :EndIf
            rr←C.libssh2_channel_write_ex ptr stream data (≢data)
            :If (rr<0)∧rr≠S.ERROR_EAGAIN
                ⎕SIGNAL⊂('EN'S.SSH_ERR)('Message' (⍕r))
            :EndIf
            (again r)←(rr=S.ERROR_AGAIN) rr
        ∇
        
        ∇(again data)←{stream} Read len;rr;d
            :Access Public
            Check
            :If 0=⎕NC'stream' ⋄ stream←0 ⋄ :EndIf
            rr d←C.libssh2_channel_read_ex ptr stream (len/0) len
            :If (rr<0)∧rr≠S.ERROR_EAGAIN
                ⎕SIGNAL⊂('EN'S.SSH_ERR)('Message' (⍕r))
            :EndIf
            (again data)←(rr=S.ERROR_EAGAIN)(rr↑data)
        ∇
        
        ⍝ See if the channel is out of data
        ∇r←EOF
            :Access Public
            Check
            r←C.libssh2_channel_eof ptr
            ⎕SIGNAL(r<0)/⊂('EN'S.SSH_ERR)('Message' (⍕r))
        ∇
        
    :EndClass
    
    ⍝ Direct TCPIP
    :Class Channel_Direct_TCPIP: Channel
        ∇init (sess desthost destport shost sport)
            :Access Public
            :Implements Constructor :Base
            
            ptr←C.libssh2_channel_direct_tcpip_ex sess.Ref desthost destport shost sport
            :If ptr=0
                'Cannot initialize channel' ⎕SIGNAL S.SSH_ERR
            :EndIf
        ∇
    :EndClass

    :Section Constants
        ⍝ The constants are named as in the C include files, but without the LIBSSH2_ prefix.

        HOSTKEY_HASH_MD5  ← 1
        HOSTKEY_HASH_SHA1 ← 2
        
        ERROR_EAGAIN      ← ¯37
        
        SSH_DISCONNECT_BY_APPLICATION ← 11

    :EndSection
    ⍝ Low-level C functions
    :Namespace C
        ∇ l←lib;isOS

            ⍝ Return the right library for our OS
            isOS←{⍵≡(≢⍵)↑⊃#.⎕WG'APLVersion'}

            :If isOS'Windows'
                l←'libssh2.dll'
            :ElseIf isOS'Linux'
            :OrIf isOS'Mac'
                l←'libssh2.so'
            :EndIf
        ∇


        ⍝ load the library functions
        ∇ LoadLib;l
            l←lib
            ⎕NA'I  ',l,'|libssh2_agent_connect&                  P'
            ⎕NA'I  ',l,'|libssh2_agent_disconnect&               P'
            ⎕NA'I  ',l,'|libssh2_agent_free                      P'
            ⎕NA'I  ',l,'|libssh2_agent_get_identity              P P P'
            ⎕NA'P  ',l,'|libssh2_version                         I'
            ⎕NA'P  ',l,'|libssh2_agent_init                      P'
            ⎕NA'I  ',l,'|libssh2_agent_list_identities           P'
            ⎕NA'I  ',l,'|libssh2_agent_userauth                  P <0C P'
            ⎕NA'I  ',l,'|libssh2_channel_close                   P'
            ⎕NA'P  ',l,'|libssh2_channel_direct_tcpip_ex&        P <0C I <0C I'
            ⎕NA'I  ',l,'|libssh2_channel_eof                     P'
            ⎕NA'I  ',l,'|libssh2_channel_flush_ex&               P I'
            ⎕NA'P  ',l,'|libssh2_channel_forward_accept&         P'
            ⎕NA'I  ',l,'|libssh2_channel_forward_cancel&         P'
            ⎕NA'P  ',l,'|libssh2_channel_forward_listen_ex&      P <0C I >I I'
            ⎕NA'I  ',l,'|libssh2_channel_free&                   P'
            ⎕NA'I  ',l,'|libssh2_channel_get_exit_signal         P >P >P >P >P >P >P'
            ⎕NA'I  ',l,'|libssh2_channel_get_exit_status         P'
            ⎕NA'I  ',l,'|libssh2_channel_handle_extended_data2   P I'
            ⎕NA'P  ',l,'|libssh2_channel_open_ex&                P <0C U U U <0C U'
            ⎕NA'I  ',l,'|libssh2_channel_process_startup&        P <0C U <0C U'
            ⎕NA'I  ',l,'|libssh2_channel_read_ex&                P I =U1[] P'
            ⎕NA'I  ',l,'|libssh2_channel_receive_window_adjust2& P U8 U1 >U'
            ⎕NA'I  ',l,'|libssh2_channel_request_pty_ex&         P <0C U <0C U I I I I'
            ⎕NA'I  ',l,'|libssh2_channel_send_eof&               P'
            ⎕NA'   ',l,'|libssh2_channel_set_blocking&           P I'
            ⎕NA'I  ',l,'|libssh2_channel_setenv_ex&              P <0C U <0C U'
            ⎕NA'I  ',l,'|libssh2_channel_wait_closed&            P'
            ⎕NA'I  ',l,'|libssh2_channel_wait_eof&               P'
            ⎕NA'U8 ',l,'|libssh2_channel_window_read_ex&         P >U8 >U8'
            ⎕NA'U8 ',l,'|libssh2_channel_window_write_ex&        P >U8'
            ⎕NA'I  ',l,'|libssh2_channel_write_ex&               P I <U1[] P'
            ⎕NA'   ',l,'|libssh2_exit'
            ⎕NA'   ',l,'|libssh2_free                            P P'
            ⎕NA'P  ',l,'|libssh2_hostkey_hash                    P I'
            ⎕NA'I  ',l,'|libssh2_init                            I'
            ⎕NA'   ',l,'|libssh2_keepalive_config                P I U'
            ⎕NA'   ',l,'|libssh2_keepalive_send                  P >I'
            ⎕NA'I  ',l,'|libssh2_knownhost_addc                  P <0C <0C <0C P <0C P I P'
            ⎕NA'I  ',l,'|libssh2_knownhost_checkp                P <0C I <0C P I P'
            ⎕NA'I  ',l,'|libssh2_knownhost_del                   P P'
            ⎕NA'   ',l,'|libssh2_knownhost_free                  P'
            ⎕NA'I  ',l,'|libssh2_knownhost_get                   P P P'
            ⎕NA'I  ',l,'|libssh2_knownhost_init                  P'
            ⎕NA'I  ',l,'|libssh2_knownhost_readfile              P <0C I'
            ⎕NA'I  ',l,'|libssh2_knownhost_readline              P <0C P I'
            ⎕NA'I  ',l,'|libssh2_knownhost_writefile             P <0C I'
            ⎕NA'I  ',l,'|libssh2_knownhost_writeline             P P =U1[] P >P I'
            ⎕NA'I  ',l,'|libssh2_poll                            ={U1 P U8 U8}[] U U8'
            ⎕NA'I  ',l,'|libssh2_publickey_add_ex                P <0C U8 <U1[] U8 I1 U8 <{P U8 P U8 I1}[]'

            ⎕NA'P  ',l,'|libssh2_scp_recv&                       P <0C P'
            ⎕NA'P  ',l,'|libssh2_scp_send64&                     P <0C I U8 P P'
            ⎕NA'P  ',l,'|libssh2_session_abstract                P'

            ⎕NA'P  ',l,'|libssh2_session_banner_get              P'
            ⎕NA'I  ',l,'|libssh2_session_banner_set              P <0C'
            ⎕NA'I  ',l,'|libssh2_session_block_directions        P'
            ⎕NA'I  ',l,'|libssh2_session_disconnect_ex&          P I <0C <0C'
            ⎕NA'I  ',l,'|libssh2_session_flag                    P I I'
            ⎕NA'I  ',l,'|libssh2_session_free                    P'
            ⎕NA'I  ',l,'|libssh2_session_get_blocking            P'
            ⎕NA'U8 ',l,'|libssh2_session_get_timeout             P'
            ⎕NA'I  ',l,'|libssh2_session_handshake&              P I'
            ⎕NA'P  ',l,'|libssh2_session_hostkey                 P >P >I'
            ⎕NA'P  ',l,'|libssh2_session_init_ex                 P P P P'
            ⎕NA'I  ',l,'|libssh2_session_last_errno              P'
            ⎕NA'I  ',l,'|libssh2_session_last_error              P >P <0C I'
            ⎕NA'I  ',l,'|libssh2_session_method_pref             P I <0C'
            ⎕NA'P  ',l,'|libssh2_session_methods                 P I'
            ⎕NA'   ',l,'|libssh2_session_set_blocking            P I'
            ⎕NA'I  ',l,'|libssh2_session_set_last_error          P I <0C'
            ⎕NA'   ',l,'|libssh2_session_set_timeout             P I8'
            ⎕NA'I  ',l,'|libssh2_session_supported_algs          P I >P'

            ⎕NA'I  ',l,'|libssh2_sftp_close_handle               P'
            ⎕NA'I  ',l,'|libssh2_sftp_fstat_ex                   P P I'
            ⎕NA'I  ',l,'|libssh2_sftp_fstatvfs                   P       >{U8 U8 U8 U8 U8 U8 U8 U8 U8 U8 U8}'
            ⎕NA'I  ',l,'|libssh2_sftp_fsync                      P'
            ⎕NA'I  ',l,'|libssh2_sftp_init                       P'
            ⎕NA'U8 ',l,'|libssh2_sftp_last_error                 P'
            ⎕NA'I  ',l,'|libssh2_sftp_mkdir_ex                   P <0C U U8'
            ⎕NA'P  ',l,'|libssh2_sftp_open_ex                    P <0C U U8 I8 I'
            ⎕NA'I  ',l,'|libssh2_sftp_read&                      P =U1[] P'
            ⎕NA'I  ',l,'|libssh2_sftp_readdir_ex                 P =U1[] P =U1[] P >{U8 U8 U8 U8 U8 U8 U8}'
            ⎕NA'I  ',l,'|libssh2_sftp_rename_ex                  P <0C U <0C U U8'
            ⎕NA'I  ',l,'|libssh2_sftp_rmdir_ex                   P <0C U'
            ⎕NA'   ',l,'|libssh2_sftp_seek64                     P U8'
            ⎕NA'I  ',l,'|libssh2_sftp_shutdown                   P'
            ⎕NA'I  ',l,'|libssh2_sftp_stat_ex                    P <0C U I >{U8 U8 U8 U8 U8 U8 U8}'
            ⎕NA'I  ',l,'|libssh2_sftp_statvfs                    P <0C P >{U8 U8 U8 U8 U8 U8 U8 U8 U8 U8 U8}'
            ⎕NA'I  ',l,'|libssh2_sftp_symlink_ex                 P <0C U <0C U I'
            ⎕NA'U8 ',l,'|libssh2_sftp_tell64                     P'
            ⎕NA'I  ',l,'|libssh2_sftp_unlink_ex                  P <0C U'
            ⎕NA'I  ',l,'|libssh2_sftp_write&                     P <0C P'

            ⎕NA'I  ',l,'|libssh2_userauth_authenticated          P'
            ⎕NA'P  ',l,'|libssh2_userauth_list                   P <0C U'
            ⎕NA'I  ',l,'|libssh2_userauth_password_ex            P <0C U <0C U P'
            ⎕NA'I  ',l,'|libssh2_userauth_publickey_fromfile_ex  P <0C U P <0C <0C'
            ⎕NA'I  ',l,'|libssh2_userauth_publickey_frommemory   P <0C U <0C U <0C U <0C'

            ⎕NA'P  ',l,'|libssh2_version                         I'


        ∇
    :EndNamespace

:EndNamespace