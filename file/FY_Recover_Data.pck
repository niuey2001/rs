create or replace package FY_Recover_Data is
  ---------------------------------------------------------------------------
  -- WWW.HelloDBA.COM                                                     ---
  -- Created By: Fuyuncat                                                 ---
  -- Created Date: 08/08/2012                                             ---
  -- Email: Fuyuncat@gmail.com                                            ---
  -- Copyright (c), 2014, WWW.HelloDBA.COM All rights reserved.           ---
  -- Latest Version: http://www.HelloDBA.com/download/FY_Recover_Data.zip ---
  --                                                                      ---
  -- Update Logs                                                          ---
  -- 15/08/2012, Fuyuncat:                                                ---
  --   1. Fixed Bug in Clean_Up_Ts (Not change TS status correctly)        ---
  --   2. Added Exception Handle when Restore Data                        ---
  --   3. Added Parameter in recover_table,                               ---
  --            to balance Fault Tolerance and Performance                ---
  --                                                                      ---
  -- 16/08/2012, Fuyuncat:                                                ---
  --   1. Enhanced corrupted block processing, get rows as possilbe       ---
  --                                                                      ---
  -- 17/08/2012, Fuyuncat:                                                ---
  --   1. Omit the LOB columns raised ORA-22922 exception                 ---
  --                                                                      ---
  -- 20/08/2012, Fuyuncat:                                                ---
  --   1. Omit the LOB columns via db link                                ---
  --                                                                      ---
  -- 22/08/2012, Fuyuncat:                                                ---
  --   1. Updated logging and tracing interface                           ---
  --                                                                      ---
  -- 19/02/2014, Fuyuncat:                                                ---
  --   1. Temp Restore and Recover tablespace & files                     ---
  --      will be created on temp folder                                  ---
  --   2. Handle tablespace has files located at diff folders             ---
  --   3. Handle tables on ASM                                            ---
  --                                                                      ---
  -- 05/03/2014, Fuyuncat:                                                ---
  --   1. Fixed bugs                                                      ---
  --   2. Use existing dirctory if applicable                             ---
  --   3. Recover data from offline files                                 ---
  ---------------------------------------------------------------------------

  type r_cursor is REF CURSOR;
  type o_fileprop is record (
   file# number,
   status$ number);
  type t_fileprops is table of o_fileprop;
  
  /************************************************************************
  ** recover truncated table
  **
  ** tgtowner: Owner of Target Table to be recovered;
  ** tgttable: Name of Target Table to be recovered;
  ** datapath: Absolute path of Data Files;
  ** fbks: block number to be filled in recovery table;
  ** offline_files: Offline data files that data should be recovered from;
  **    foramt: full_path_file1;full_path_file2...;
  ************************************************************************/
  procedure recover_truncated_table( tow varchar2, 
                                     ttb varchar2,
                                     fbks number default 1, 
                                     tmppath varchar2 default null,
                                     offline_files varchar2 default null);

  /************************************************************************
  ** dump a block in raw, for testing
  **
  ** hdfile: Data file name;
  ** srcdir: data file directory
  ** blknb: block number to be dumped;
  ** blksz: block size;
  ************************************************************************/
  procedure dump_seg_block_raw( hdfile varchar2,
                                srcdir varchar2, 
                                blknb number,
                                blksz number default 8192);
/*
  procedure test_chain(filename varchar2, 
                       blknum number, 
                       startpos number,
                       repcont raw,
                       srcdir varchar2 default 'FY_DATA_DIR');
*/
  /************************************************************************
  ** Set Initial parameters
  **
  ** tracing: trace the process for debug;
  ** logging: show logging information;
  ** repobjid: replace the data object id wiht the recover table data object id;
  ************************************************************************/
  procedure init_set( tracing boolean default true,
                      logging boolean default true,
                      repobjid boolean default true);
end FY_Recover_Data;
/
create or replace package body FY_Recover_Data is
  ---------------------------------------------------------------------------
  -- WWW.HelloDBA.COM                                                     ---
  -- Created By: Fuyuncat                                                 ---
  -- Created Date: 08/08/2012                                             ---
  -- Email: Fuyuncat@gmail.com                                            ---
  -- Copyright (c), 2014, WWW.HelloDBA.COM All rights reserved.            ---
  -- Latest Version: http://www.HelloDBA.com/download/FY_Recover_Data.zip   ---
  ---------------------------------------------------------------------------

  s_tracing       boolean:= false;
  s_logging       boolean:= true;
  s_repobjid      boolean:= false;
  
  procedure init_set (tracing boolean default true,
                      logging boolean default true,
                      repobjid boolean default true)
  as
  begin
    s_tracing := tracing;
    s_logging := logging;
    s_repobjid := repobjid;
  end;
  
  procedure trace (msg varchar2)
  as
  begin
    if s_tracing then
      dbms_output.put_line(to_char(sysdate, 'HH24:MI:SS')||': '||msg);
    end if;
  end;

  procedure log (msg varchar2)
  as
  begin
    if s_logging then
      dbms_output.put_line(to_char(sysdate, 'HH24:MI:SS')||': '||msg);
    end if;
  end;

  function d2r (dig varchar2,
                len number default 0)
  return raw
  is
  begin
    --trace('[d2r] hextoraw(lpad(trim(to_char('||dig||', ''XXXXXXXX'')),'||len||',''0''))');
    return hextoraw(lpad(trim(to_char(dig, 'XXXXXXXX')),len,'0'));
  end;                

  /************************************************************************
  ** Copy file
  **
  ** srcdir: Directory of Source File;
  ** srcfile: Source File Name;
  ** dstdir: Directory of Destination File;
  ** dstfile: Destination File Name;
  ************************************************************************/
  procedure copy_file(srcdir varchar2, 
                      srcfile varchar2, 
                      dstdir varchar2, 
                      dstfile in out varchar2)
  as
    --p_srcdir varchar2(255) := upper(srcdir);
    --p_srcfile varchar2(255) := upper(srcfile);
    --p_dstdir varchar2(255) := upper(dstdir);
    --p_dstfile varchar2(255) := upper(dstfile);
    p_srcdir varchar2(255) := srcdir;
    p_srcfile varchar2(255) := srcfile;
    p_dstdir varchar2(255) := dstdir;
    p_dstfile varchar2(255) := dstfile;
    file_copied boolean := false;
    retries pls_integer := 0;
  begin
    if dstdir is null then
      p_dstdir := p_srcdir;
    end if;
    if dstfile is null then
      p_dstfile := p_srcfile||'$';
      dstfile := p_dstfile;
    end if;
    while not file_copied loop
    begin
      trace('[copy_file] begin copy file: '||p_srcdir||'\'||p_srcfile||' => '||p_dstdir||'\'||p_dstfile);--'
      DBMS_FILE_TRANSFER.copy_file(p_srcdir, p_srcfile, p_dstdir, p_dstfile);
      trace('[copy_file] completed.');
      file_copied := true;
    exception when others then
      -- file already exists
      if sqlcode = -19504 and instr(dbms_utility.format_error_stack,'ORA-27038')>0 and retries < 10 then
        trace('[copy_file] file '||p_dstdir||'\'||p_dstfile||' exists, rename to '||dstfile||retries);
        retries := retries+1;
        p_dstfile := dstfile||retries;
        file_copied := false;
      else 
        --log(dbms_utility.format_error_backtrace);
        file_copied := true;
        raise;
      end if;
    end;
    end loop;
    dstfile := p_dstfile;
  end;

  /************************************************************************
  ** Remove file
  **
  ** dir: Directory of the File;
  ** file: File to be removed;
  ************************************************************************/
  procedure remove_file(dir varchar2, 
                        file varchar2)
  as
  begin
    trace('[remove_file] Begin to remove file '||dir||'/'||file);
    utl_file.fremove(dir,file);
    trace('[remove_file] '||dir||'/'||file||' has been removed.');
  end;

  function gen_table_name(tgttable varchar2,
                          plus     varchar2 default '',
                          genowner varchar2 default user)
  return varchar2
  as
    gentab varchar2(30);
  begin
    select upper(tgttable||plus||surfix) into gentab from (select surfix from (select null surfix from dual union all select level surfix from dual connect by level <= 255) where not exists (select 1 from dba_tables where owner = genowner and table_name = upper(tgttable||plus||surfix)) order by surfix nulls first) where rownum<=1;
    return gentab;
  end;

  function gen_file_name( tgtfile varchar2,
                          plus    varchar2 default '')
  return varchar2
  as
    genfile varchar2(30);
    slash char(1);
  begin
    select decode(instr(platform_name, 'Windows'),0,'/','\') into slash from v_$database where rownum<=1;
    select tgtfile||plus||surfix||'.DAT' into genfile from (select surfix from (select null surfix from dual union all select level surfix from dual connect by level <= 255) where not exists (select 1 from dba_data_files where file_name like '%'||slash||tgtfile||plus||surfix||'.DAT') order by surfix nulls first) where rownum<=1; --'
    return genfile;
  end;

  function gen_ts_name( tgtts  varchar2,
                        plus   varchar2 default '')
  return varchar2
  as
    gents varchar2(30);
  begin
    select tgtts||plus||surfix into gents from (select surfix from (select null surfix from dual union all select level surfix from dual connect by level <= 255) where not exists (select 1 from dba_tablespaces where tablespace_name = tgtts||plus||surfix) order by surfix nulls first) where rownum<=1;
    return gents;
  end;

  procedure create_directory (path varchar2,
                              dir in out varchar2)
  as
    exists_path pls_integer;
    exists_dir varchar2(256);
    slash char(1);
  begin
    select decode(instr(platform_name, 'Windows'),0,'/','\') into slash from v_$database where rownum<=1;
    -- windows
    if slash='\' then
      select count(1), max(directory_name) into exists_path, exists_dir from dba_directories 
       where owner=user 
         and upper(directory_path)||decode(substr(directory_path,length(directory_path)),slash,'',slash)
             =
             upper(path)||decode(substr(path,length(path)),slash,'',slash);
    else -- linux/unix
      select count(1), max(directory_name) into exists_path, exists_dir from dba_directories 
       where owner=user 
         and directory_path||decode(substr(directory_path,length(directory_path)),slash,'',slash)
             =
             path||decode(substr(path,length(path)),slash,'',slash);
    end if;
    trace('[create_directory] Exists directory number '||exists_path);
    if exists_path=0 then
      select dir||surfix into dir from (select surfix from (select null surfix from dual union all select level surfix from dual connect by level <= 255) where not exists (select 1 from dba_directories where directory_name = dir||surfix) order by surfix nulls first) where rownum<=1;
      log('New Directory Name: '||dir);
      execute immediate 'create directory '||dir||' as '''||path||'''';
    else
      dir := exists_dir;
      log('Use existing Directory Name: '||dir);
    end if;
  end;

  procedure replace_segmeta_in_file(tmpdir varchar2, 
                                    tmpcopyf varchar2, 
                                    dstdir varchar2, 
                                    dstfile in out varchar2,
                                    dstisfilesystem boolean,
                                    tgtobjid number,
                                    newobjid number, 
                                    dtail raw,
                                    addpos number,
                                    addinfo raw,
                                    blksz number default 8192,
                                    endianess number default 1)
  as
    bfr    utl_file.file_type;
    bfw    utl_file.file_type; 
    hsz    number := 24;
    objr   raw(4);
    objn   number;
    dhead  raw(32);
    dbody  raw(32767);
    nbody  raw(32767);
    p_tmpdir varchar2(255) := tmpdir;
    p_tmpcopyf varchar2(255) := tmpcopyf;
    p_dstdir varchar2(255) := dstdir;
    p_tmpdstfile varchar2(255);
    p_finaldstdir varchar2(255);
  begin
    if p_dstdir is null then
      p_dstdir := p_tmpdir;
    end if;
    trace('[replace_objid_in_file] replace object id in '||tmpdir||'\'||tmpcopyf||' ['||tgtobjid||' => '||newobjid||']'); --'
    if not dstisfilesystem then
      p_tmpdstfile := gen_file_name(dstfile,'');
      copy_file(dstdir,dstfile,p_tmpdir,p_tmpdstfile);
      p_finaldstdir := p_tmpdir;
    else
      p_tmpdstfile := dstfile;
      p_finaldstdir := p_dstdir;
    end if;
    bfr := utl_file.fopen(p_tmpdir, p_tmpcopyf, 'RB');
    bfw := utl_file.fopen(p_finaldstdir, p_tmpdstfile, 'WB');
    while true loop
    begin
      nbody := '';
      utl_file.get_raw(bfr, dhead, hsz);
      exit when dhead is null;
      utl_file.get_raw(bfr, dbody, blksz-hsz);
      --objr := hextoraw(substrb(rawtohex(dbody), 1, 8));
      objr := utl_raw.substr(dbody, 1, 4);
      if endianess > 0 then
        objn := to_number(rawtohex(utl_raw.reverse(objr)), 'XXXXXXXX');
      else
        objn := to_number(rawtohex(objr), 'XXXXXXXX');
      end if;
      -- replace data object id with the recover object id
      --if objn = tgtobjid and substrb(rawtohex(dhead), 1, 2) = '06' then
      if objn = tgtobjid then
        if addpos <= hsz then
          --utl_file.put_raw(bfw, utl_raw.concat(utl_raw.substr(dhead, 1, addpos-1), addinfo, utl_raw.substr(dhead, addpos+utl_raw.length(addinfo))));
          nbody := utl_raw.concat(nbody, utl_raw.substr(dhead, 1, addpos-1), addinfo, utl_raw.substr(dhead, addpos+utl_raw.length(addinfo)));
        else
          --utl_file.put_raw(bfw, dhead);
          nbody := utl_raw.concat(nbody, dhead);
        end if;
        --utl_file.put_raw(bfw, utl_raw.concat(utl_raw.substr(dhead, 1, 8), addinfo, utl_raw.substr(dhead, 9+utl_raw.length(addinfo))));
        --nbody := utl_raw.concat(nbody, utl_raw.substr(dhead, 1, 8), addinfo, utl_raw.substr(dhead, 9+utl_raw.length(addinfo)));
        --trace('[replace_objid_in_file] old id in raw: '||rawtohex(objr));
        if endianess > 0 then
          --trace('[replace_objid_in_file] new id in raw: '||utl_raw.reverse(d2r(newobjid, 8)));
          --utl_file.put_raw(bfw, utl_raw.reverse(d2r(newobjid, 8)));
          nbody := utl_raw.concat(nbody, utl_raw.reverse(d2r(newobjid, 8)));
        else
          --trace('[replace_objid_in_file] new id in raw: '||(d2r(newobjid, 8)));
          --utl_file.put_raw(bfw, d2r(newobjid, 8));
          nbody := utl_raw.concat(nbody, d2r(newobjid, 8));
        end if;
        -- skip objid
        if addpos > hsz+5 and addinfo is not null then
          trace('[replace_objid_in_file] old body len: '||utl_raw.length(dbody)||' new = 4 + '||utl_raw.length(utl_raw.substr(dbody, 5, addpos-hsz-5))||' + '||utl_raw.length(addinfo)||' + '||utl_raw.length(utl_raw.substr(dbody, addpos-hsz-4+utl_raw.length(addinfo), blksz-(addpos-1)-utl_raw.length(dtail)-utl_raw.length(addinfo)))||' + 4');
          --utl_file.put_raw(bfw, utl_raw.concat(utl_raw.substr(dbody, 5, addpos-hsz-5), addinfo, utl_raw.substr(dbody, addpos-hsz, blksz-(addpos-1)-utl_raw.length(dtail)-utl_raw.length(addinfo))));
          nbody := utl_raw.concat(nbody, utl_raw.substr(dbody, 5, addpos-hsz-5), addinfo, utl_raw.substr(dbody, addpos-hsz-4+utl_raw.length(addinfo), blksz-(addpos-1)-utl_raw.length(dtail)-utl_raw.length(addinfo)));
          --trace('[replace_objid_in_file] new body len: '||utl_raw.length(nbody));
        elsif addpos = hsz+5 and addinfo is not null then
          --utl_file.put_raw(bfw, utl_raw.concat(addinfo, utl_raw.substr(dbody, addpos-hsz, blksz-(addpos-1)-utl_raw.length(dtail)-utl_raw.length(addinfo))));
          nbody := utl_raw.concat(nbody, addinfo, utl_raw.substr(dbody, addpos-hsz, blksz-(addpos-1)-utl_raw.length(dtail)-utl_raw.length(addinfo)));
        else
          --utl_file.put_raw(bfw, utl_raw.substr(dbody, 5, blksz-hsz-4-utl_raw.length(dtail)));
          nbody := utl_raw.concat(nbody, utl_raw.substr(dbody, 5, blksz-hsz-4-utl_raw.length(dtail)));
        end if;
        --trace('[replace_objid_in_file] tail in raw: '||dtail||'('||utl_raw.length(dtail)||')');
        --utl_file.put_raw(bfw, dtail);
        nbody := utl_raw.concat(nbody, dtail);
        trace('[replace_objid_in_file] new body length: '||utl_raw.length(nbody));
      else
        --utl_file.put_raw(bfw, dhead);
        --utl_file.put_raw(bfw, dbody);
        nbody := utl_raw.concat(nbody, dhead, dbody);
      end if;
      --if utl_raw.length(nbody) != blksz then
      --  trace('[replace_objid_in_file] new body length: '||utl_raw.length(nbody));
      --end if;
      utl_file.put_raw(bfw, nbody);

      utl_file.fflush(bfw);
      exception
        when no_data_found then
          exit;
        when others then
          trace('[replace_objid_in_file] '||SQLERRM);
          trace('[replace_objid_in_file] '||dbms_utility.format_error_backtrace);
          exit;
    end;
    end loop;
    utl_file.fclose(bfw);
    utl_file.fclose(bfr);
    if not dstisfilesystem then
      copy_file(p_tmpdir,p_tmpdstfile,dstdir,dstfile);
      remove_file(p_tmpdir,p_tmpdstfile);
    end if;
    trace('[replace_objid_in_file] completed.');
  end;

  function get_cols_no_lob( recowner varchar2, 
                            rectab varchar2)
  return varchar2
  as
    cols        varchar2(32767);
    colno       number := 0;
  begin
    cols := '';
    for col_rec in (select column_name, data_type, nullable from dba_tab_cols where owner = recowner and table_name = rectab) loop
      if col_rec.data_type NOT LIKE '%LOB' then
        if colno > 0 then
          cols := cols||',';
        end if;
        cols := cols||col_rec.column_name;
        colno := colno + 1;
      end if;
    end loop;
    return cols;
  end;

  function restore_table_row_no_lob(recowner varchar2, 
                                    rectab varchar2, 
                                    rstowner varchar2, 
                                    rsttab varchar2,
                                    cols varchar2,
                                    rid rowid)
  return number
  as
    recnum      number := 0;
  begin
    begin
      execute immediate 'insert /*+*/ into '||rstowner||'.'||rsttab||'('||cols||') select '||cols||' from '||recowner||'.'||rectab||' where rowid = :rid' using rid;
      recnum := recnum + SQL%ROWCOUNT;
    exception when others then
      trace('[restore_table_row_no_lob] '||SQLERRM);
      trace('[restore_table_row_no_lob] '||dbms_utility.format_error_backtrace);
      null;
    end;  
    return recnum;
  end;

  function restore_table_in_rows( recowner varchar2, 
                                  rectab varchar2, 
                                  rstowner varchar2, 
                                  rsttab varchar2)
  return number
  as
    recnum      number := 0;
    blk_cur     r_cursor;
    objid       number;
    fid         number;
    blkno       number;
    rnum        number;
    gnum        number;
    cols        varchar2(32767);
  begin
    begin
      --trace('[restore_table_in_rows] '||'select dbms_rowid.rowid_object(rowid) objid, dbms_rowid.rowid_relative_fno(rowid) fid, dbms_rowid.rowid_block_number(rowid) blkno, count(1) rnum from '||recowner||'.'||rectab||' group by dbms_rowid.rowid_object(rowid), dbms_rowid.rowid_relative_fno(rowid), dbms_rowid.rowid_block_number(rowid)');
      open blk_cur for 'select dbms_rowid.rowid_object(rowid) objid, dbms_rowid.rowid_relative_fno(rowid) fid, dbms_rowid.rowid_block_number(rowid) blkno, count(1) rnum from '||recowner||'.'||rectab||' group by dbms_rowid.rowid_object(rowid), dbms_rowid.rowid_relative_fno(rowid), dbms_rowid.rowid_block_number(rowid)';
      loop
        fetch blk_cur into objid, fid, blkno, rnum;
        exit when blk_cur%NOTFOUND;
        trace('[restore_table_in_rows] expected rows: '||rnum);
        gnum := 0;
        --trace('[restore_table_in_rows] block: '||blkno);
        for i in 1..rnum loop
        begin
          --trace('[restore_table_in_rows] row: '||i);
          --execute immediate 'insert /*+*/into '||rstowner||'.'||rsttab||' select * from '||recowner||'.'||rectab||' where rowid = dbms_rowid.rowid_create(1, :objid, :fid, :blkno, :i)' using objid, fid, blkno, i-1;
          execute immediate 'insert /*+*/into '||rstowner||'.'||rsttab||' select * from '||recowner||'.'||rectab||' where dbms_rowid.rowid_relative_fno(ROWID)=:fid and dbms_rowid.rowid_block_number(ROWID)=:blkno and dbms_rowid.rowid_row_number(ROWID)=:i' using fid, blkno, i-1;
          recnum := recnum + SQL%ROWCOUNT;
          gnum := gnum + SQL%ROWCOUNT;
        exception when others then
          if sqlcode = -22922 then
            -- trace('[restore_table_in_rows] Warning: Unrecoverable Lob found!');
            if cols is null then
              cols := get_cols_no_lob(recowner, rectab);
            end if;
            recnum := recnum + restore_table_row_no_lob(recowner, rectab, rstowner, rsttab, cols, dbms_rowid.rowid_create(1, objid, fid, blkno, i-1));
          else
            trace('[restore_table_in_rows] '||SQLERRM);
            trace('[restore_table_in_rows] '||dbms_utility.format_error_backtrace);
          end if;
          null;
        end;
        end loop;
        if gnum != rnum then
          log('Warning: '||(rnum-gnum)||' records lost!');
        end if;
      end loop;
      exception when others then
        trace('[restore_table_in_rows] '||sqlerrm);
        trace('[restore_table_in_rows] '||dbms_utility.format_error_backtrace);
        null;
    end;  
    return recnum;
  end;

  function restore_table_in_rows_remote(recowner varchar2, 
                                        rectab varchar2, 
                                        rstowner varchar2, 
                                        rsttab varchar2,
                                        dblink varchar2)
  return number
  as
    recnum      number := 0;
    blk_cur     r_cursor;
    objid       number;
    fid         number;
    blkno       number;
    rnum        number;
    cols        varchar2(32767);
  begin
    begin
      --rollback;
      open blk_cur for 'select dbms_rowid.rowid_object(rowid) objid, dbms_rowid.rowid_relative_fno(rowid) fid, dbms_rowid.rowid_block_number(rowid) blkno, count(1) rnum from '||recowner||'.'||rectab||' group by dbms_rowid.rowid_object(rowid), dbms_rowid.rowid_relative_fno(rowid), dbms_rowid.rowid_block_number(rowid)';
      loop
        fetch blk_cur into objid, fid, blkno, rnum;
        exit when blk_cur%NOTFOUND;
        trace('[restore_table_in_rows_remote] expected rows: '||rnum);
        for i in 1..rnum loop
        begin
          --execute immediate 'insert /*+no_append*/into '||rstowner||'.'||rsttab||' select * from '||recowner||'.'||rectab||'@'||dblink||' where rowid = dbms_rowid.rowid_create(1, :objid, :fid, :blkno, :i)' using objid, fid, blkno, i-1;
          execute immediate 'insert /*+*/into '||rstowner||'.'||rsttab||' select * from '||recowner||'.'||rectab||'@'||dblink||' where dbms_rowid.rowid_relative_fno(ROWID)=:fid and dbms_rowid.rowid_block_number(ROWID)=:blkno and dbms_rowid.rowid_row_number(ROWID)=:i' using fid, blkno, i-1;
          recnum := recnum + SQL%ROWCOUNT;
          --commit;
        exception when others then
          if sqlcode = -22922 then
            if cols is null then
              cols := get_cols_no_lob(recowner, rectab);
            end if;
            recnum := recnum + restore_table_row_no_lob(recowner, rectab, rstowner, rsttab, cols, dbms_rowid.rowid_create(1, objid, fid, blkno, i-1));
          else
            trace('[restore_table_in_rows_remote] '||SQLERRM);
            trace('[restore_table_in_rows_remote] '||dbms_utility.format_error_backtrace);
            --commit;
          end if;
          null;
        end;
        end loop;
      end loop;
    end;  
    return recnum;
  end;

  function restore_table_ctas(recowner varchar2, 
                              rectab varchar2, 
                              rstowner varchar2, 
                              rsttab varchar2)
  return number
  as
    recnum      number := 0;
    tmptab      varchar2(30);
  begin
    tmptab := gen_table_name(rsttab, '', rstowner);
    begin
      execute immediate 'create table '||rstowner||'.'||tmptab||' as select /*+full(t)*/* from '||recowner||'.'||rectab||' t';
      execute immediate 'insert /*+append*/ into '||rstowner||'.'||rsttab||' select /*+full(t)*/* from '||recowner||'.'||tmptab||' t';
      recnum := SQL%ROWCOUNT;
      execute immediate 'drop table '||rstowner||'.'||tmptab;
      exception when others then
        --trace('[restore_table_ctas] '||SQLERRM);
        --trace('[restore_table_ctas] '||dbms_utility.format_error_backtrace);
        null;
    end;  
    return recnum;
  end;

  function restore_table_no_lob(recowner varchar2, 
                                rectab varchar2, 
                                rstowner varchar2, 
                                rsttab varchar2)
  return number
  as
    recnum      number := 0;
    cols        varchar2(32767);
  begin
    cols := get_cols_no_lob(recowner, rectab);

    begin
      --execute immediate 'alter system flush buffer_cache';
      execute immediate 'insert /*+append*/ into '||rstowner||'.'||rsttab||'('||cols||') select /*+full(t)*/'||cols||' from '||recowner||'.'||rectab||' t';

      recnum := recnum + SQL%ROWCOUNT;
    exception when others then
      --raise;
      if sqlcode = -22922 then
        null;
      else
        recnum := recnum + restore_table_in_rows(recowner, rectab, rstowner, rsttab);
      end if;
    end;
    trace('[restore_table_no_lob] '||recnum||' records recovered');
    return recnum;
  end;
 
  function restore_table( recowner varchar2, 
                          rectab varchar2, 
                          rstowner varchar2, 
                          rsttab varchar2,
                          selflink varchar2 default '')
  return number
  as
    recnum      number := 0;
    expnum      number := 0;
  begin
    begin
      trace('[restore_table] Trying to restore data to '||rstowner||'.'||rsttab);
      execute immediate 'alter system flush buffer_cache';
      if s_tracing then
        execute immediate 'select /*+full(t)*/count(*) from '||recowner||'.'||rectab||' t' into expnum;
        trace('[restore_table] Expected Records in this round: '||expnum);
      end if;
      execute immediate 'insert /*+append*/ into '||rstowner||'.'||rsttab||' select /*+full(t)*/* from '||recowner||'.'||rectab||' t';

      recnum := recnum + SQL%ROWCOUNT;
      if s_tracing and expnum != SQL%ROWCOUNT then
        trace('[restore_table] '||(expnum-SQL%ROWCOUNT)||' records lost!');
        return -1; -- for test
      end if;
    exception when others then
      --raise;
      if sqlcode = -22922 then
        log('Warning: Unrecoverable Lob found!');
        recnum := recnum + restore_table_in_rows_remote(recowner, rectab, rstowner, rsttab, selflink);
        --recnum := recnum + restore_table_no_lob(recowner, rectab, rstowner, rsttab);
      else
        trace(SQLERRM);
        trace('[restore_table] '||dbms_utility.format_error_backtrace);
        --recnum := recnum + restore_table_in_rows_remote(recowner, rectab, rstowner, rsttab, selflink);
        --return -1; -- test
        recnum := recnum + restore_table_in_rows(recowner, rectab, rstowner, rsttab);
      end if;
    end;
    execute immediate 'alter system flush buffer_cache';
    trace('[restore_table] '||recnum||' records recovered');
    return recnum;
  end;
 
  procedure get_seg_meta( segowner varchar2,
                          segname varchar2,
                          tmpdir varchar2,
                          dtail out raw, 
                          addinfo out raw, 
                          blksz number default 8192)
  as
    frw    raw(32767);
    firstblk  number;
    slash char(1);
    hdfile varchar2(255);
    hdfpath varchar2(4000);
    hdfdir varchar2(255) := 'TMP_HF_DIR'; 
    finaldir varchar2(255);
    bfo    utl_file.file_type;
    i      number := 0;
  begin
    select decode(instr(platform_name, 'Windows'),0,'/','\') into slash from v_$database where rownum<=1;
    select header_block+1 into firstblk from dba_segments where owner = segowner and segment_name = segname;
    select substr(file_name,instr(d.file_name, slash, -1)+1),
           substr(file_name,1,instr(d.file_name, slash, -1))
             into hdfile, hdfpath
      from dba_data_files d, dba_segments s where s.header_file = d.file_id and s.owner = segowner and s.segment_name = segname; --'

    trace('[get_seg_meta] '||hdfpath||hdfile);
    create_directory(hdfpath,hdfdir);
    -- copy ASM file to temp os folder
    if hdfpath like '+%' or hdfpath like '/dev/%' then
      copy_file(hdfdir,hdfile,tmpdir,hdfile);
      finaldir := tmpdir;
    else
      finaldir := hdfdir;
    end if;

    bfo := utl_file.fopen(finaldir, hdfile, 'RB');

    -- reach to the truncated data blocks
    i := 0;
    while true loop
    begin
      utl_file.get_raw(bfo, frw, blksz);
      i := i+1;

      exit when i = firstblk;
      exception when others then
        exit;
    end;
    end loop;
    
    utl_file.get_raw(bfo, frw, blksz);

    dtail := utl_raw.substr(frw, blksz-3, 4);
    addinfo := utl_raw.substr(frw, 39, 2);
    
    utl_file.fclose(bfo);
    
    if hdfpath like '+%' or hdfpath like '/dev/%' then
      remove_file(tmpdir,hdfile);
    end if;
    -- execute immediate 'drop directory '||hdfdir;
  end;

  function get_seg_data_id( segowner varchar2,
                            segname varchar2,
                            tmpdir varchar2, 
                            blksz number default 8192,
                            endianess number default 1)
  return number                            
  as
    frw    raw(32767);
    hsz    number := 28;
    firstblk  number;
    slash char(1);
    hdfile varchar2(255);
    hdfpath varchar2(4000);
    hdfdir varchar2(255) := 'TMP_HF_DIR';
    finaldir varchar2(255);
    bfo    utl_file.file_type;
    i      number := 0;
    objr   raw(4);
    objn   number;
  begin
    select decode(instr(platform_name, 'Windows'),0,'/','\') into slash from v_$database where rownum<=1;
    select header_block+1 into firstblk from dba_segments where owner = segowner and segment_name = segname;
    select substr(file_name,instr(d.file_name, slash, -1)+1),
           substr(file_name,1,instr(d.file_name, slash, -1))
             into hdfile, hdfpath
      from dba_data_files d, dba_segments s where s.header_file = d.file_id and s.owner = segowner and s.segment_name = segname; --'

    trace('[get_seg_data_id] '||hdfpath||hdfile);
    create_directory(hdfpath,hdfdir);
    -- copy ASM file to temp os folder
    if hdfpath like '+%' or hdfpath like '/dev/%' then
      copy_file(hdfdir,hdfile,tmpdir,hdfile);
      finaldir := tmpdir;
    else
      finaldir := hdfdir;
    end if;

    bfo := utl_file.fopen(finaldir, hdfile, 'RB');

    -- reach to the truncated data blocks
    i := 0;
    while true loop
    begin
      utl_file.get_raw(bfo, frw, blksz);
      i := i+1;

      exit when i = firstblk;
      exception when others then
        exit;
    end;
    end loop;
    
    utl_file.get_raw(bfo, frw, hsz);

    objr := utl_raw.substr(frw, 25, 4);
    if endianess > 0 then
      objn := to_number(rawtohex(utl_raw.reverse(objr)), 'XXXXXXXX');
    else
      objn := to_number(rawtohex(objr), 'XXXXXXXX');
    end if;
    
    utl_file.fclose(bfo);
    
    if hdfpath like '+%' or hdfpath like '/dev/%' then
      remove_file(tmpdir,hdfile);
    end if;
    -- execute immediate 'drop directory '||hdfdir;
    return objn;
  end;

  /************************************************************************
  ** Recover Table Data From Special Data File;
  **
  ** oriobjid: Object Id of Table to be Recovered;
  ** recowner: Owner of Table to be used as recovering dummy table;
  ** rectable: Name of Table to be used as recovering dummy table;
  ** rstowner: Owner of Table to store the recovered data;
  ** rsttable: Name of Table to store the recovered data;
  ** srcdir: Directory of the Data File to be recovered;
  ** srcfile: Name of the Data File to be recovered;
  ** srcisfilesystem: Is the source file located in file system or not;
  ** tmpdir: Temp Directory to create restore tablespace and other temp files;
  ** recfile: Name of Data File that rectable is stored;
  ** coryfile: Name of Copy of Data File that rectable is stored;
  ** blksz: Block size of the Tablespace Storing the Table to be recovered;
  ** selflink: database link refer to instance self connect to dba account;
  ************************************************************************/
  procedure recover_table(oriobjid number,
                          recowner varchar2, 
                          rectab varchar2, 
                          rstowner varchar2, 
                          rsttab varchar2,
                          srcdir varchar2,
                          srcfile varchar2, 
                          srcisfilesystem boolean, 
                          tmpdir varchar2, 
                          recfile varchar2, 
                          copyfile varchar2, 
                          blksz number default 8192,
                          fillblks number default 5,
                          selflink varchar2 default '',
                          endianess number default 1,
                          recnum in out number,
                          truncblks in out number)
  as
    p_tmpsrcfile varchar2(30);
    p_finalsrcdir varchar2(255);
    -- blk    blob;
    --vrw    raw(32767);
    frw    raw(32767);
    tsz    number := 4;
    hsz    number := 28;
    objr   raw(4);
    objn   number;
    dtail  raw(4);
    dhead  raw(32);
    dbody  raw(32767);
    --bfr    bfile;
    bfo    utl_file.file_type;
    bfr    utl_file.file_type;
    bfw    utl_file.file_type; 
    fillednum number := 0;
    dummyheader number;
    dummyblks   number;
    blkstofill  number := fillblks;
    i           number := 0;
    j           number := 0;
    rstnum      number := 0;
  begin
    select header_block+1, blocks-3 into dummyheader, dummyblks from dba_segments where owner = recowner and segment_name = rectab;
    if blkstofill > dummyblks then
      blkstofill := dummyblks;
    end if;
    
    if not srcisfilesystem then
      p_tmpsrcfile := gen_file_name(srcfile,'');
      copy_file(srcdir, srcfile,tmpdir,p_tmpsrcfile);
      p_finalsrcdir := tmpdir;
    else
      p_tmpsrcfile := srcfile;
      p_finalsrcdir := srcdir;
    end if;

    bfo := utl_file.fopen(p_finalsrcdir, p_tmpsrcfile, 'RB');
    --utl_file.get_raw(bfo, dbody, blksz-hsz-tsz);
    --utl_file.get_raw(bfo, dtail, tsz);

    bfr := utl_file.fopen(tmpdir, copyfile, 'RB');
    bfw := utl_file.fopen(tmpdir, recfile, 'WB');
    -- reach to the transaction blocks to be filled
    i := 0;
    while true loop
    begin
      utl_file.get_raw(bfr, frw, blksz);
      utl_file.put_raw(bfw, frw);
      i := i+1;

      exit when i=dummyheader+fillednum;
      exception when others then
        --raise;
        --trace('[recover_table] block NO.: '||i);
        exit;
    end;
    end loop;
    
    -- go through the data file of truncated table
    while true loop
    begin
      --trace('[recover_table] '||j);
      j := j+1;
      --objr := substrb(rawtohex(dhead), 49, 8);
      utl_file.get_raw(bfo, dhead, hsz);
      if hsz <= 24 then
        utl_file.get_raw(bfo, dbody, blksz-tsz-hsz);
        --objr := substrb(rawtohex(dbody), 49-hsz*2, 8);
        objr := utl_raw.substr(dbody, 25-hsz, 4);
      else
        --objr := substrb(rawtohex(dhead), 49, 8);
        objr := utl_raw.substr(dhead, 25, 4);
      end if;
      if endianess > 0 then
        --objn := to_number(utl_raw.reverse(hextoraw(objr)), 'XXXXXXXX');
        objn := to_number(rawtohex(utl_raw.reverse(objr)), 'XXXXXXXX');
      else
        --objn := to_number(hextoraw(objr), 'XXXXXXXX');
        objn := to_number(rawtohex(objr), 'XXXXXXXX');
      end if;

      -- check if block belongs to truncated table
      if objn != oriobjid or substrb(rawtohex(dhead), 1, 2) != '06' then
        if hsz > 24 then
          utl_file.get_raw(bfo, dbody, blksz-hsz);
        else
          utl_file.get_raw(bfo, dtail, tsz);
        end if;
      else
        --trace('[recover_table] Find it.');
        truncblks := truncblks + 1;
        if hsz > 24 then
          utl_file.get_raw(bfo, dbody, blksz-hsz-tsz);
        end if;
        utl_file.get_raw(bfo, dtail, tsz);

        if not utl_file.is_open(bfr) then
          bfr := utl_file.fopen(tmpdir, copyfile, 'RB');
        end if;
        if not utl_file.is_open(bfw) then
          bfw := utl_file.fopen(tmpdir, recfile, 'WB');
        end if;

        -- filling the trans block
        utl_file.get_raw(bfr, dhead, hsz);
        utl_file.put_raw(bfw, dhead); -- put original header
        utl_file.put_raw(bfw, dbody); -- replace body
        utl_file.get_raw(bfr, dbody, blksz-hsz-tsz); -- forward pointer in original file copy
        utl_file.get_raw(bfr, dtail, tsz); -- get original tail
        utl_file.put_raw(bfw, dtail); -- put original tail
        fillednum := fillednum+1;
        i := i+1;
        -- no trans data block left, copy recovered data to backup table and fill the left blocks
        if fillednum >= blkstofill then
        --if fillednum+blkstofill-1 >= dummyblks then
        begin
          while true loop
          begin
            utl_file.get_raw(bfr, frw, blksz);
            utl_file.put_raw(bfw, frw);
            i := i+1;

            exception when others then
              if utl_file.is_open(bfr) then
                utl_file.fclose(bfr);
              end if;
              if utl_file.is_open(bfw) then
                utl_file.fclose(bfw);
              end if;
              exit;
          end;
          end loop;

          rstnum := restore_table(recowner, rectab, rstowner, rsttab, selflink);
          -- for test
          exit when rstnum < 0;
          recnum := recnum+rstnum;
          fillednum := 0;
          commit;

          bfr := utl_file.fopen(tmpdir, copyfile, 'RB');
          bfw := utl_file.fopen(tmpdir, recfile, 'WB');
          -- go to the transaction blocks again
          i := 0;
          while true loop
          begin
            utl_file.get_raw(bfr, frw, blksz);
            utl_file.put_raw(bfw, frw);
            i := i+1;

            exit when i=dummyheader+fillednum;
            exception when others then
              --raise;
              --trace('[recover_table] block NO.: '||i);
              exit;
          end;
          end loop;
          utl_file.fflush(bfw);
          exception when others then
            trace('[recover_table 2-1] '||sqlerrm);
            trace('[recover_table 2-1] '||dbms_utility.format_error_backtrace);
            null;
          end;
        end if;
      end if;
      exception 
        when no_data_found then
          exit;
        when others then
          trace('[recover_table 2-2] '||sqlerrm);
          trace('[recover_table 2-2] '||dbms_utility.format_error_backtrace);
          exit;
    end;
    end loop;

    -- last blocks not full filled dummy table
    --if fillednum+blkstofill-1 < dummyblks then
    if fillednum < blkstofill and rstnum>=0 then
    begin
      while true loop
      begin
        utl_file.get_raw(bfr, frw, blksz);
        utl_file.put_raw(bfw, frw);
        i := i+1;

        exception when others then
          if utl_file.is_open(bfr) then
            utl_file.fclose(bfr);
          end if;
          if utl_file.is_open(bfw) then
            utl_file.fclose(bfw);
          end if;
          exit;
      end;
      end loop;
      recnum := recnum+restore_table(recowner, rectab, rstowner, rsttab, selflink);
      --fillednum := 0;
      commit;
    end;
    end if;
    if utl_file.is_open(bfr) then
      utl_file.fclose(bfr);
    end if;
    if utl_file.is_open(bfw) then
      utl_file.fclose(bfw);
    end if;
    if utl_file.is_open(bfo) then
      utl_file.fclose(bfo);
    end if;
    utl_file.fclose_all();

    log(truncblks||' truncated data blocks found. ');
    log(recnum||' records recovered in backup table '||rstowner||'.'||rsttab);
    
    if not srcisfilesystem then
      remove_file(tmpdir,p_tmpsrcfile);
    end if;
  end;

  /************************************************************************
  ** Recover Table Data From Data Files of Targe Table;
  **
  ** tgtowner: Owner of Target Table to be recovered;
  ** tgttable: Name of Target Table to be recovered;
  ** recowner: Owner of Table to be used as recovering dummy table;
  ** rectable: Name of Table to be used as recovering dummy table;
  ** rstowner: Owner of Table to store the recovered data;
  ** rsttable: Name of Table to store the recovered data;
  ** tmpdir: Temp Directory to create restore tablespace and other temp files;
  ** srcfile: Name of the Data File to be recovered;
  ** recfile: Name of Data File that rectable is stored;
  ** copydir: Directory of Copy of Data File that rectable is stored;
  ** coryfile: Name of Copy of Data File that rectable is stored;
  ** blksz: Block size of the Tablespace Storing the Table to be recovered;
  ** selflink: database link refer to instance self connect to dba account;
  ************************************************************************/
  procedure recover_table(tgtowner varchar2,
                          tgttable varchar2,
                          recowner varchar2, 
                          rectab varchar2, 
                          rstowner varchar2, 
                          rsttab varchar2, 
                          tmpdir varchar2, 
                          recfile varchar2, 
                          copyfile varchar2, 
                          blksz number default 8192,
                          fillblks number default 5,
                          selflink varchar2 default '',
                          offline_files varchar2 default null)
  as
    tgtobjid    number;
    recobjid    number;
    endianess   number;
    slash       char(1);
    filedir     varchar2(255) := 'TMP_DATA_FILE_DIR';
    tmpcopyf    varchar2(256);
    tsname      varchar2(30);
    readprop    varchar2(30);
    dtail       raw(4);
    addinfo     raw(32);
    recnum      number := 0;
    truncblks   number := 0;
    trecnum     number := 0;
    ttruncblks  number := 0;
  begin
    execute immediate 'truncate table '||rstowner||'.'||rsttab;
    execute immediate 'alter system set db_block_checking=false scope=memory';
    execute immediate 'alter system set db_block_checksum=false scope=memory';
    execute immediate 'alter system set "_db_block_check_objtyp"=false scope=memory';
    execute immediate 'alter session set events ''10231 trace name context forever, level 10''';
    execute immediate 'alter session set events ''10233 trace name context forever, level 10''';

    select instr(platform_name, 'Windows'), decode(instr(platform_name, 'Windows'),0,'/','\') into endianess, slash from v_$database where rownum<=1;
    select data_object_id into recobjid from dba_objects where owner = recowner and object_name = rectab and object_type='TABLE' and rownum<=1;
    log('begin to recover table '||tgtowner||'.'||tgttable);
    tgtobjid := get_seg_data_id(tgtowner, tgttable, tmpdir, blksz, endianess);

    if offline_files is not null then
      for file_rec in (with target_string as (select /*+inline*/offline_files str, ';' spliter from dual),
                                    files as (select trim(regexp_substr(str, '[^'||spliter||']+', 1, level)) file_name  
                                                from target_string
                                              connect by level <= length (regexp_replace (str, '[^'||spliter||']+'))  + 1)
                       select substr(file_name,instr(file_name, slash, -1)+1) as filename,
                              substr(file_name,1,instr(file_name, slash, -1)) as filepath 
                         from files
                        where file_name is not null) loop --'
      begin
        log('Recovering data in datafile '||file_rec.filepath||file_rec.filename);
        recnum := 0;
        truncblks := 0;
        create_directory(file_rec.filepath,filedir);
        recover_table(tgtobjid, recowner, rectab, rstowner, rsttab, filedir, file_rec.filename, (file_rec.filepath not like '+%' and file_rec.filepath not like '/dev/%'), tmpdir, recfile, copyfile, blksz, fillblks, selflink, endianess, recnum, truncblks);
        -- execute immediate 'drop directory '||filedir;
        trecnum := trecnum + recnum;
        ttruncblks := ttruncblks + truncblks;
      exception when others then
        trace('[recover_table 1] '||sqlerrm);
        trace('[recover_table 1] '||dbms_utility.format_error_backtrace);
      end;
      end loop;
    else
      if s_repobjid then
        get_seg_meta(recowner, rectab, tmpdir, dtail, addinfo, blksz);
        select tablespace_name into tsname from dba_tables where owner = tgtowner and table_name = tgttable and rownum<=1;
        select STATUS into readprop from dba_tablespaces where tablespace_name = tsname;
        if readprop != 'READ ONLY' then
          execute immediate 'alter tablespace '||tsname||' read only';
          execute immediate 'alter system flush buffer_cache';
        end if;
        --for file_rec in (select substr(file_name,decode(instr(d.file_name, '\', -1), 0, instr(file_name, '/', -1), instr(file_name, '\', -1))+1) as filename,
        --                        substr(file_name,1,decode(instr(d.file_name, '\', -1), 0, instr(file_name, '/', -1), instr(file_name, '\', -1))) as filepath  
        --                   from dba_data_files d, dba_tables t 
        --                   where d.tablespace_name = t.tablespace_name and t.owner = tgtowner and t.table_name = tgttable) loop --'
        for file_rec in (select substr(file_name,instr(d.file_name, slash, -1)+1) as filename,
                                substr(file_name,1,instr(d.file_name, slash, -1)) as filepath  
                           from dba_data_files d, dba_tables t 
                           where d.tablespace_name = t.tablespace_name and t.owner = tgtowner and t.table_name = tgttable) loop --'
        begin
          log('Recovering data in datafile '||file_rec.filepath||file_rec.filename);
          recnum := 0;
          truncblks := 0;
          create_directory(file_rec.filepath,filedir);
          tmpcopyf := gen_file_name(file_rec.filename, '');
          copy_file(filedir, file_rec.filename, tmpdir, tmpcopyf);
          --replace_segmeta_in_file(srcdir, tmpcopyf, srcdir, file_rec.filename, tgtobjid, recobjid, dtail, 39, addinfo, blksz, endianess);
          replace_segmeta_in_file(tmpdir, tmpcopyf, filedir, file_rec.filename, (file_rec.filepath not like '+%' and file_rec.filepath not like '/dev/%'), tgtobjid, recobjid, dtail, 39, '', blksz, endianess);
          recover_table(recobjid, recowner, rectab, rstowner, rsttab, filedir, file_rec.filename, (file_rec.filepath not like '+%' and file_rec.filepath not like '/dev/%'), tmpdir, recfile, copyfile, blksz, fillblks, selflink, endianess, recnum, truncblks);
          --recover_table(tgtobjid, recowner, rectab, rstowner, rsttab, srcdir, file_rec.filename, recdir, recfile, copydir, copyfile, blksz, fillblks, selflink, endianess);
          copy_file(tmpdir, tmpcopyf, filedir, file_rec.filename);
          remove_file(tmpdir, tmpcopyf);
          -- execute immediate 'drop directory '||filedir;
          trecnum := trecnum + recnum;
          ttruncblks := ttruncblks + truncblks;
          trace('[recover_table 1] '||tmpcopyf||' removed.');
        exception when others then
          trace('[recover_table 1] '||sqlerrm);
          trace('[recover_table 1] '||dbms_utility.format_error_backtrace);
        end;
        end loop;
        if readprop != 'READ ONLY' then
          execute immediate 'alter tablespace '||tsname||' read write';
        end if;
      else
        for file_rec in (select substr(file_name,instr(d.file_name, slash, -1)+1) as filename,
                                substr(file_name,1,instr(d.file_name, slash, -1)) as filepath  
                           from dba_data_files d, dba_tables t 
                           where d.tablespace_name = t.tablespace_name and t.owner = tgtowner and t.table_name = tgttable) loop --'
        begin
          log('Recovering data in datafile '||file_rec.filepath||file_rec.filename);
          recnum := 0;
          truncblks := 0;
          create_directory(file_rec.filepath,filedir);
          recover_table(tgtobjid, recowner, rectab, rstowner, rsttab, filedir, file_rec.filename, (file_rec.filepath not like '+%' and file_rec.filepath not like '/dev/%'), tmpdir, recfile, copyfile, blksz, fillblks, selflink, endianess, recnum, truncblks);
          -- execute immediate 'drop directory '||filedir;
          trecnum := trecnum + recnum;
          ttruncblks := ttruncblks + truncblks;
        exception when others then
          trace('[recover_table 1] '||sqlerrm);
          trace('[recover_table 1] '||dbms_utility.format_error_backtrace);
        end;
        end loop;
      end if;
    end if;

    log('Total: '||ttruncblks||' truncated data blocks found. ');
    log('Total: '||trecnum||' records recovered in backup table '||rstowner||'.'||rsttab);

    execute immediate 'alter session set events ''10233 trace name context off''';
    execute immediate 'alter session set events ''10231 trace name context off''';
    execute immediate 'alter system set "_db_block_check_objtyp"=true scope=memory';
    execute immediate 'alter system set db_block_checksum=true scope=memory';
    execute immediate 'alter system set db_block_checking=true scope=memory';

    log('Recovery completed.');
  end;
  
  /************************************************************************
  ** Prepare the data files to be use during recovering;
  **
  ** tgtowner: Owner of Target Table to be recovered;
  ** tgttable: Name of Target Table to be recovered;
  ** datapath: Absolute path of Data Files;
  ** datadir: Directory to be created referring to datapath;
  ** rects: Tablespace to store the recovering dummy table;
  ** recfile: Name of Data File to store the recovering dummy table;
  ** rstts: Tablespace to store table storing the recovered data;
  ** rstfile: Name of Data File to store restoring table;
  ** blksz: Block size of the Tablespace Storing the Table to be recovered;
  ** rectsblks: block number of recovery tablespace
  ** rectsblks: block number of restore tablespace
  ************************************************************************/
  procedure prepare_files(tgtowner varchar2,
                          tgttable varchar2,
                          tmppath varchar2,
                          rects out varchar2, 
                          recfile out varchar2, 
                          rstts out varchar2, 
                          rstfile out varchar2, 
                          blksz out varchar2,
                          rectsblks number default 16,
                          rsttsblks number default 2560)
  as
    ext_mgmt   varchar2(30);
    ss_mgmt    varchar2(30);
    slash      char(1);
  begin
    select decode(instr(platform_name, 'Windows'),0,'/','\') into slash from v_$database where rownum<=1;

    select block_size, extent_management, segment_space_management into blksz, ext_mgmt, ss_mgmt from dba_tablespaces ts, dba_tables t where t.tablespace_name = ts.tablespace_name and t.owner = upper(tgtowner) and t.table_name = upper(tgttable);

    --select 'FY_REC_DATA'||surfix into rects from (select surfix from (select null surfix from dual union all select level surfix from dual connect by level <= 255) where not exists (select 1 from dba_tablespaces where tablespace_name = 'FY_REC_DATA'||surfix) order by surfix nulls first) where rownum<=1;
    --select 'FY_REC_DATA'||surfix||'.DAT' into recfile from (select surfix from (select null surfix from dual union all select level surfix from dual connect by level <= 255) where not exists (select 1 from dba_data_files where file_name like '%\FY_REC_DATA'||surfix||'.DAT') order by surfix nulls first) where rownum<=1;
    rects := gen_ts_name('FY_REC_DATA','');
    recfile := gen_file_name('FY_REC_DATA','');
    log('Recover Tablespace: '||rects||'; Data File: '||recfile);
    execute immediate 'create tablespace '||rects||' datafile '''||rtrim(tmppath, slash)||slash||recfile||''' size '||to_char(blksz*rectsblks/1024)||'K autoextend off extent management '||ext_mgmt||' SEGMENT SPACE MANAGEMENT '||ss_mgmt; --'

    --select 'FY_RST_DATA'||surfix into rstts from (select surfix from (select null surfix from dual union all select level surfix from dual connect by level <= 255) where not exists (select 1 from dba_tablespaces where tablespace_name = 'FY_REST_DATA'||surfix) order by surfix nulls first) where rownum<=1;
    --select 'FY_RST_DATA'||surfix||'.DAT' into rstfile from (select surfix from (select null surfix from dual union all select level surfix from dual connect by level <= 255) where not exists (select 1 from dba_data_files where file_name like '%\FY_REST_DATA'||surfix||'.DAT') order by surfix nulls first) where rownum<=1;
    rstts := gen_ts_name('FY_RST_DATA','');
    rstfile := gen_file_name('FY_RST_DATA','');
    log('Restore Tablespace: '||rstts||'; Data File: '||rstfile);
    execute immediate 'create tablespace '||rstts||' datafile '''||rtrim(tmppath, slash)||slash||rstfile||''' size '||to_char(blksz*rsttsblks/1024)||'K autoextend on extent management '||ext_mgmt||' SEGMENT SPACE MANAGEMENT '||ss_mgmt; --'
  end;

  /************************************************************************
  ** Clean up existing Recover and Restore Tablespace. Drop tables in the tablespaces
  **
  ** rects: Recover tablespace name
  ** rects: Restore tablespace name, default NULL, will not do cleaning up;
  ************************************************************************/
  procedure clean_up_ts(rects varchar2, 
                        rstts varchar2 default null)
  as
    readprop varchar2(30);
  begin
    select STATUS into readprop from dba_tablespaces where tablespace_name = rects;
    if readprop = 'READ ONLY' then
      execute immediate 'alter tablespace '||rects||' read write';
    end if;
    for tab_rec in (select owner, table_name from dba_tables where tablespace_name = rects) loop
      execute immediate 'drop table '||tab_rec.owner||'.'||tab_rec.table_name;
    end loop;
    if rstts is not null then
      for tab_rec in (select owner, table_name from dba_tables where tablespace_name = rstts) loop
        execute immediate 'drop table '||tab_rec.owner||'.'||tab_rec.table_name;
      end loop;
    end if;
  end;

  /************************************************************************
  ** Fill Blocks of Recovering Table, to format the blocks;
  **
  ** tgtowner: Owner of Target Table to be recovered;
  ** tgttable: Name of Target Table to be recovered;
  ** tmpdir: Temp Directory to be used to create the restore tablespace and files;
  ** rects: Tablespace to store the recovering dummy table;
  ** recfile: Name of Data File to store the recovering dummy table;
  ** rstts: Tablespace to store table storing the recovered data;
  ** blks: Number blocks in Initial Extent of the recovering dummy table;
  ** recowner: Owner of Table to be used as recovering dummy table;
  ** rstowner: Owner of Table to store the recovered data;
  ** rectable: Name of Table to be used as recovering dummy table;
  ** rsttable: Name of Table to store the recovered data;
  ** coryfile: Name of Copy of Data File that rectable is stored;
  ************************************************************************/
  procedure fill_blocks(tgtowner varchar2,
                        tgttable varchar2,
                        tmpdir varchar2, 
                        rects varchar2,
                        recfile varchar2,
                        rstts varchar2,
                        blks number default 8,
                        recowner varchar2 default user,
                        rstowner varchar2 default user,
                        rectab in out varchar2,
                        rsttab in out varchar2,
                        copyfile out varchar2)
  as
    blksz  number;
    blkno  number;
    cols   varchar2(32767);
    vals   varchar2(32767);
    colno  number := 0;
  begin
    if rectab is null then
      select block_size into blksz from dba_tablespaces ts, dba_tables t where t.tablespace_name = ts.tablespace_name and t.owner = upper(tgtowner) and t.table_name = upper(tgttable);
      -- select upper(tgttable||'$'||surfix) into rectab from (select surfix from (select null surfix from dual union all select level surfix from dual connect by level <= 255) where not exists (select 1 from dba_tables where owner = recowner and table_name = upper(tgttable||'$'||surfix)) order by surfix nulls first) where rownum<=1;
      rectab := gen_table_name(tgttable, '$', recowner);
      log('Recover Table: '||recowner||'.'||rectab);
      --trace('[fill_blocks] create table '||recowner||'.'||rectab||' tablespace '||rects||' storage(initial '||to_char(blks*blksz/1024)||'K) as select * from '||tgtowner||'.'||tgttable||' where 1=2');
      execute immediate 'create table '||recowner||'.'||rectab||' tablespace '||rects||' storage(initial '||to_char(blks*blksz/1024)||'K) as select * from '||tgtowner||'.'||tgttable||' where 1=2';
    else
      --execute immediate 'truncate table '||recowner||'.'||rectab;
      execute immediate 'delete from '||recowner||'.'||rectab;
      commit;
    end if;

    cols := '';
    vals := '';
    for col_rec in (select column_name, data_type, nullable from dba_tab_cols where owner = recowner and table_name = rectab) loop
      if col_rec.nullable = 'N' then
        execute immediate 'alter table '||recowner||'.'||rectab||' modify '||col_rec.column_name||' null';
      end if;
      if colno < 6 then
        if col_rec.data_type like '%CHAR%' or col_rec.data_type like '%RAW%' then
          if colno > 0 then
            cols := cols||',';
            vals := vals||',';
          end if;
          cols := cols||col_rec.column_name;
          vals := vals||'''A''';
          colno := colno + 1;
       elsif col_rec.data_type like '%NUMBER%' or col_rec.data_type = 'FLOAT' then
          if colno > 0 then
            cols := cols||',';
            vals := vals||',';
          end if;
          cols := cols||col_rec.column_name;
          vals := vals||'0';
          colno := colno + 1;
       elsif col_rec.data_type LIKE '%TIMESTAMP%' or col_rec.data_type = 'DATE' then
          if colno > 0 then
            cols := cols||',';
            vals := vals||',';
          end if;
          cols := cols||col_rec.column_name;
          vals := vals||'sysdate';
          colno := colno + 1;
       end if;
      end if;
    end loop;

    --select upper(tgttable||'$$'||surfix) into rsttab from (select surfix from (select null surfix from dual union all select level surfix from dual connect by level <= 255) where not exists (select 1 from dba_tables where owner = rstowner and table_name = upper(tgttable||'$$'||surfix)) order by surfix nulls first) where rownum<=1;
    if rsttab is null then
      rsttab := gen_table_name(tgttable, '$$', rstowner);
      log('Restore Table: '||rstowner||'.'||rsttab);
      execute immediate 'create table '||rstowner||'.'||rsttab||' tablespace '||rstts||' as select * from '||recowner||'.'||rectab||' where 1=2';
    else
      execute immediate 'truncate table '||rstowner||'.'||rsttab;
    end if;

    --trace('[fill_blocks] insert into '||recowner||'.'||rectab||'('||cols||') values ('||vals||')');
    while true loop
      execute immediate 'insert into '||recowner||'.'||rectab||'('||cols||') values ('||vals||')';
      execute immediate 'select count(unique(dbms_rowid.rowid_block_number( rowid ))) from '||recowner||'.'||rectab into blkno ;
      exit when blkno >= blks-3;
    end loop;
    commit;
    execute immediate 'alter system flush buffer_cache';
    execute immediate 'delete from '||recowner||'.'||rectab;
    commit;
    execute immediate 'alter system flush buffer_cache';
    trace('[fill_blocks] Data Blocks formatted.');

    execute immediate 'alter tablespace '||rects||' read only';

    select 'FY_REC_DATA_COPY'||surfix||'.DAT' into copyfile from (select surfix from (select null surfix from dual union all select level surfix from dual connect by level <= 255) where not exists (select 1 from dba_data_files where file_name like '%FY_REC_DATA_COPY'||surfix||'.DAT') order by surfix nulls first) where rownum<=1;
    copy_file(tmpdir, recfile, tmpdir, copyfile);
    log('Copy file of Recover Tablespace: '||copyfile);
  end;

  /************************************************************************
  ** Create recovery table on new file of truncated table's tablespace;
  **
  ** tgtowner: Owner of Target Table to be recovered;
  ** tgttable: Name of Target Table to be recovered;
  ** datadir: Directory to be created referring to datapath;
  ** rects: Tablespace to store the recovering dummy table;
  ** recfid: ID of Data File to store the recovering dummy table;
  ** recfile: Name of Data File to store the recovering dummy table;
  ** rectable: Name of Table to be used as recovering dummy table;
  ** blks: Number blocks in Initial Extent of the recovering dummy table;
  ** rectsblks: block number of recovery tablespace
  ************************************************************************/
  procedure create_rectab_on_tgttab_ts( tgtowner varchar2,
                                        tgttable varchar2,
                                        datadir varchar2, 
                                        recowner varchar2 default user,
                                        rects out varchar2,
                                        recfid in out number,
                                        recfile out varchar2,
                                        rectab out varchar2,
                                        blks number default 8,
                                        rectsblks number default 16)
  as
    blksz  number;
    tsid   number;
    tsonline number;
    datapath varchar2(32767);
    r_files r_cursor;
    filelist t_fileprops;
    tn     number;
  begin
    select ts.ts#, ts.name, ts.online$, blocksize into tsid, rects, tsonline, blksz from sys.ts$ ts, dba_tables t where t.tablespace_name = ts.name and t.owner = upper(tgtowner) and t.table_name = upper(tgttable);
    if tsonline = 4 then
      execute immediate 'alter tablespace '||rects||' read write';
    end if;

    if recfid is null then
      open r_files for select file#,status$ bulk from sys.file$ where ts#=tsid;
      fetch r_files bulk collect into filelist;
      recfile := gen_file_name('FY_REC_DATA','');
      select rtrim(directory_path, '\')||'\' into datapath from dba_directories where directory_name = datadir; --'
      execute immediate 'alter tablespace '||rects||' add datafile '''||datapath||recfile||''' size '||to_char(rectsblks*blksz/1024)||'K';
      select file_id into recfid from dba_data_files where tablespace_name = rects and (file_name like '%\'||recfile or file_name like '%/'||recfile); --'
    else
      open r_files for select file#,status$ bulk from sys.file$ where ts#=tsid and file#!=recfid;
      fetch r_files bulk collect into filelist;
      trace('[create_rectab_on_tgttab_ts] file id: '||recfid);
      select decode(instr(file_name, '/', -1), 0, substr(file_name,instr(file_name, '\', -1)+1), substr(file_name,instr(file_name, '/', -1)+1)) into recfile from dba_data_files where file_id = recfid; --'
    end if;
    log('Recover Tablespace: '||recfile||'('||recfid||')');
    for i in 1..filelist.count loop
      update sys.file$ f set status$=1 where ts#=tsid and file# = filelist(i).file#;
    end loop;
    commit;
    execute immediate 'alter system flush buffer_cache';
    --select file# into tn from sys.file$ where ts#=tsid and status$=2;
    --trace('[create_rectab_on_tgttab_ts] inactive files: '||filelist.count);
    --trace('[create_rectab_on_tgttab_ts] active file id: '||tn);
    rectab := gen_table_name(tgttable, '$', recowner);
    log('Recover Table: '||recowner||'.'||rectab);
    --dbms_lock.sleep(3);
    execute immediate 'create table '||recowner||'.'||rectab||' tablespace '||rects||' storage(initial '||to_char(blks*blksz/1024)||'K) as select * from '||tgtowner||'.'||tgttable||' where 1=2';
    select header_file  into tn from dba_segments where owner = recowner and segment_name = rectab;
    trace('[create_rectab_on_tgttab_ts] header file: '||filelist.count);
    for i in 1..filelist.count loop
      update sys.file$ f set status$=filelist(i).status$ where ts#=tsid and file# = filelist(i).file#;
    end loop;
    commit;
    execute immediate 'alter system flush buffer_cache';
  end;

  procedure replace_segraw_in_file( srcdir varchar2, 
                                    srcfile varchar2, 
                                    dstdir varchar2, 
                                    dstfile varchar2,
                                    blknum number,
                                    startpos number,
                                    repcont raw,
                                    blksz number default 8192)
  as
    bfr    utl_file.file_type;
    bfw    utl_file.file_type; 
    dbody  raw(32767);
    i      number;
    p_srcdir varchar2(255) := srcdir;
    p_srcfile varchar2(255) := srcfile;
    p_dstdir varchar2(255) := dstdir;
    p_dstfile varchar2(255) := dstfile;
  begin
    if p_dstdir is null then
      p_dstdir := p_srcdir;
    end if;
    trace('[replace_segraw_in_file] replace block id: '||blknum||' start: '||startpos||' content: '||repcont);
    bfr := utl_file.fopen(p_srcdir, p_srcfile, 'RB');
    bfw := utl_file.fopen(p_dstdir, p_dstfile, 'WB');

    i := 0;
    while true loop
    begin
      utl_file.get_raw(bfr, dbody, blksz);
      utl_file.put_raw(bfw, dbody);
      i := i+1;

      exit when i = blknum-1;
      exception when others then
        exit;
    end;
    end loop;

    utl_file.get_raw(bfr, dbody, blksz);
    if startpos<=1 then
      utl_file.put_raw(bfw, utl_raw.concat(repcont, utl_raw.substr(dbody, 1+utl_raw.length(repcont))));
    else
      utl_file.put_raw(bfw, utl_raw.concat(utl_raw.substr(dbody, 1, startpos-1), repcont, utl_raw.substr(dbody, startpos+utl_raw.length(repcont))));
    end if;

    while true loop
    begin
      utl_file.get_raw(bfr, dbody, blksz);
      utl_file.put_raw(bfw, dbody);

      exception
        when no_data_found then
          exit;
        when others then
          trace('[replace_segraw_in_file] '||SQLERRM);
          trace('[replace_segraw_in_file] '||dbms_utility.format_error_backtrace);
          exit;
    end;
    end loop;

    utl_file.fclose(bfw);
    utl_file.fclose(bfr);
    trace('[replace_segraw_in_file] completed.');
  end;

  procedure dump_seg_block_raw( hdfile varchar2,
                                srcdir varchar2, 
                                blknb number,
                                blksz number default 8192)
  as
    frw    raw(32767);
    bfo    utl_file.file_type;
    bfw    utl_file.file_type;
    i      number := 0;
  begin
    bfo := utl_file.fopen(srcdir, hdfile, 'RB');
    bfw := utl_file.fopen(srcdir, hdfile||'_'||blknb||'.BLK', 'WB');

    -- reach to the truncated data blocks
    i := 0;
    while true loop
    begin
      utl_file.get_raw(bfo, frw, blksz);
      i := i+1;

      exit when i = blknb;
      exception when others then
        exit;
    end;
    end loop;
    
    utl_file.get_raw(bfo, frw, blksz);
    utl_file.put_raw(bfw, frw);

    utl_file.fclose(bfo);
    utl_file.fclose(bfw);
  end;
/*------------------------------------------------------------------------------------------
  procedure test_chain(filename varchar2, 
                       blknum number, 
                       startpos number,
                       repcont raw,
                       srcdir varchar2 default 'FY_DATA_DIR')
  as
    tmpcopyf varchar2(256);
  begin
    execute immediate 'alter system set db_block_checking=false scope=memory';
    execute immediate 'alter system set db_block_checksum=false scope=memory';
    execute immediate 'alter system set "_db_block_check_objtyp"=false scope=memory';
    execute immediate 'alter session set events ''10231 trace name context forever, level 10''';
    execute immediate 'alter session set events ''10233 trace name context forever, level 10''';
    begin
      tmpcopyf := gen_file_name(filename, '$');
      trace('[test_chain] bakcup file '||tmpcopyf);
      copy_file(srcdir, filename, srcdir, tmpcopyf);
      replace_segraw_in_file(srcdir, tmpcopyf, srcdir, filename, blknum, startpos, repcont, 8192);
      execute immediate 'alter system flush buffer_cache';
      for rec in (select * from t_chain where rowid='AABFUoAAHAAAABFAAA') loop
        null;
      end loop;
      trace('[test_chain] table query completed');
    exception when others then
      trace('[test_chain] '||sqlerrm);
      trace('[test_chain] '||dbms_utility.format_error_backtrace);
    end;
    copy_file(srcdir, tmpcopyf, srcdir, filename);
    remove_file(srcdir, tmpcopyf);
    trace('[test_chain] '||tmpcopyf||' removed.');
    execute immediate 'alter system set db_block_checking=true scope=memory';
    execute immediate 'alter system set db_block_checksum=true scope=memory';
    execute immediate 'alter system set "_db_block_check_objtyp"=true scope=memory';
    execute immediate 'alter session set events ''10231 trace name context off''';
    execute immediate 'alter session set events ''10233 trace name context off''';
  exception when others then
    trace('[test_chain] '||sqlerrm);
    trace('[test_chain] '||dbms_utility.format_error_backtrace);
  end;
------------------------------------------------------------------------------------------*/
  procedure test_rec1( tow varchar2 default 'DEMO', 
                       ttb varchar2 default 'T_CHAIN',
                       fbks number default 1, 
                       tmppath varchar2 default '/tmp/') --'
  as
    tgtowner varchar2(30):= upper(tow);
    tgttable varchar2(30):= upper(ttb);
    tmpdir varchar2(30);
    rects varchar2(30);
    recfile varchar2(30); 
    rstts varchar2(30);
    rstfile varchar2(30);
    blksz number;
    rectab varchar2(30);
    rsttab varchar2(30);
    copyfile varchar2(30);
  begin
    tmpdir := 'FY_DATA_DIR';
    create_directory(tmppath, tmpdir);
    prepare_files(tgtowner, tgttable, tmpdir, rects, recfile, rstts, rstfile, blksz);
    rects := 'FY_REC_DATA';
    rstts := 'FY_RST_DATA';
    recfile := 'FY_REC_DATA.DAT';
    fill_blocks(tgtowner, tgttable, tmpdir, rects, recfile, rstts, 8, tgtowner, tgtowner, rectab, rsttab, copyfile);
    recover_table(tgtowner, tgttable, tgtowner, rectab, tgtowner, rsttab, tmpdir, recfile, copyfile, blksz, fbks, 'myself');
    -- execute immediate 'drop directory '||tmpdir;
  end;

  procedure test_rec2( tow varchar2 default 'DEMO', 
                       ttb varchar2 default 'T_CHAIN',
                       fbks number default 1)
  as
    tgtowner varchar2(30):= upper(tow);
    tgttable varchar2(30):= upper(ttb);
    tmpdir varchar2(30);
    rects varchar2(30);
    recfile varchar2(30); 
    rstts varchar2(30);
    blksz number;
    rectab varchar2(30);
    rsttab varchar2(30);
    copyfile varchar2(30);
  begin
    tmpdir := 'FY_DATA_DIR';
    rects := 'FY_REC_DATA';
    rstts := 'FY_RST_DATA';
    recfile := 'FY_REC_DATA.DAT';
    clean_up_ts(rects, rstts);
    select block_size into blksz from dba_tablespaces ts, dba_tables t where ts.tablespace_name = t.tablespace_name and t.owner = tgtowner and t.table_name = tgttable;
    fill_blocks(tgtowner, tgttable, tmpdir, rects, recfile, rstts, 8, tgtowner, tgtowner, rectab, rsttab, copyfile);
    recover_table(tgtowner, tgttable, tgtowner, rectab, tgtowner, rsttab, tmpdir, recfile, copyfile, blksz, fbks, 'myself');
    -- execute immediate 'drop directory '||tmpdir;
  end;

  procedure test_rec3( tow varchar2 default 'DEMO', 
                       ttb varchar2 default 'T_CHAIN',
                       fbks number default 1,
                       fid number default null)
  as
    tgtowner varchar2(30):= upper(tow);
    tgttable varchar2(30):= upper(ttb);
    tmpdir varchar2(30);
    rects varchar2(30);
    recfile varchar2(30); 
    rstts varchar2(30);
    blksz number;
    rectab varchar2(30);
    rsttab varchar2(30);
    copyfile varchar2(30);
    recfid number:= fid;
  begin
    tmpdir := 'FY_DATA_DIR';
    rstts := 'FY_RST_DATA';
    --begin
    --  execute immediate 'drop table '||tgtowner||'.'||tgttable||'$';
    --  execute immediate 'drop table '||tgtowner||'.'||tgttable||'$$';
    --exception when others then
    --  null;
    --end;
    create_rectab_on_tgttab_ts(tgtowner, tgttable, tmpdir, tgtowner, rects, recfid, recfile, rectab, 8, 16);
    select block_size into blksz from dba_tablespaces ts, dba_tables t where ts.tablespace_name = t.tablespace_name and t.owner = tgtowner and t.table_name = tgttable;
    fill_blocks(tgtowner, tgttable, tmpdir, rects, recfile, rstts, 8, tgtowner, tgtowner, rectab, rsttab, copyfile);
    recover_table(tgtowner, tgttable, tgtowner, rectab, tgtowner, rsttab, tmpdir, recfile, copyfile, blksz, fbks, 'myself');
    -- execute immediate 'drop directory '||tmpdir;
    begin
      --execute immediate 'drop table '||tgtowner||'.'||rectab;
      --execute immediate 'alter tablespace '||rects||' drop datafile '||recfid;
    --exception when others then
      null;
    end;
  end;

  procedure recover_truncated_table( tow varchar2, 
                                     ttb varchar2,
                                     fbks number default 1, 
                                     tmppath varchar2 default null,
                                     offline_files varchar2 default null) --'
  as
    tgtowner varchar2(30):= upper(tow);
    tgttable varchar2(30):= upper(ttb);
    tmpdir varchar2(30);
    rects varchar2(30);
    recfile varchar2(30); 
    rstts varchar2(30);
    rstfile varchar2(30);
    blksz number;
    rectab varchar2(30);
    rsttab varchar2(30);
    copyfile varchar2(30);
    fy_ts_cnt number:= 0;
    endianess pls_integer;
    temppath varchar2(32767):=tmppath;
  begin
    select instr(platform_name, 'Windows') into endianess from v_$database where rownum<=1;
    if temppath is null then
      if endianess > 0 then
        temppath:='c:\temp\';
      else
        temppath:='/tmp/';
      end if;
    end if;
    dbms_output.enable(999999);
    tmpdir := 'FY_DATA_DIR';
    rects := 'FY_REC_DATA';
    rstts := 'FY_RST_DATA';
    recfile := 'FY_REC_DATA.DAT';
    create_directory(temppath, tmpdir);
    select count(*) into fy_ts_cnt from dba_tablespaces where tablespace_name in (rects,rstts);
    if fy_ts_cnt = 2 then
      clean_up_ts(rects, rstts);
      select substr(file_name,decode(instr(file_name, '\', -1), 0, instr(file_name, '/', -1), instr(file_name, '\', -1))+1)
               into recfile
        from dba_data_files
       where tablespace_name = rects
         and rownum<=1;
    else
      prepare_files(tgtowner, tgttable, temppath, rects, recfile, rstts, rstfile, blksz);
    end if;
    select block_size into blksz from dba_tablespaces ts, dba_tables t where ts.tablespace_name = t.tablespace_name and t.owner = tgtowner and t.table_name = tgttable;
    fill_blocks(tgtowner, tgttable, tmpdir, rects, recfile, rstts, 8, tgtowner, tgtowner, rectab, rsttab, copyfile);
    recover_table(tgtowner, tgttable, tgtowner, rectab, tgtowner, rsttab, tmpdir, recfile, copyfile, blksz, fbks, 'myself', offline_files);
    log('Data has been recovered to '||tgtowner||'.'||rsttab);
    --execute immediate 'DROP TABLESPACE '||rects||' INCLUDING CONTENTS AND DATAFILES ';
    --execute immediate 'DROP TABLESPACE '||rstts||' INCLUDING CONTENTS AND DATAFILES ';
    --remove_file(tmpdir,recfile);
    --remove_file(tmpdir,rstfile);
    remove_file(tmpdir,copyfile);
    -- execute immediate 'DROP DIRECTORY '||tmpdir;
  end;

begin
  null;
end FY_Recover_Data;
/
