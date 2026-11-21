"""Generate tiny synthetic local video/audio; requires ffmpeg. No personal files are read."""
from pathlib import Path
import subprocess
import os
assert os.environ.get('OFFLINEKIT_HOME'), 'Set OFFLINEKIT_HOME to a disposable test folder'
root=Path(os.environ['OFFLINEKIT_HOME'])/'OfflineKit/Library/Media'
for name,color,genre in [('Across the Valley','#354d3c','Adventure'),('Coastal Trail','#48617d','Adventure'),('River Journey','#6d6946','Documentary'),('Under the Stars','#252b51','Animation')]:
    target=root/'Video'/genre/(name+'.mp4');target.parent.mkdir(parents=True,exist_ok=True)
    if not target.exists(): subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-f','lavfi','-i',f'color=c={color}:s=960x540:r=8','-t','65','-metadata','title='+name,'-metadata','genre='+genre,'-metadata','date=2024','-c:v','libx264','-preset','ultrafast','-pix_fmt','yuv420p',str(target)],check=True)
for album,artist,genre in [('Evening Light','Mara Ellis','Folk'),('Quiet Seasons','Mara Ellis','Folk'),('Sunday Jazz','North Street Quartet','Jazz')]:
    for n,title in enumerate(['First Light','The Long Way Home'],1):
        target=root/'Music'/artist/album/(f'{n:02d} - {title}.m4a');target.parent.mkdir(parents=True,exist_ok=True)
        if not target.exists(): subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-f','lavfi','-i','sine=frequency=220:duration=40','-af','volume=0.005','-metadata','title='+title,'-metadata','album='+album,'-metadata','artist='+artist,'-metadata','album_artist='+artist,'-metadata','genre='+genre,'-metadata','track='+str(n),'-metadata','date=2024','-c:a','aac',str(target)],check=True)
for book,author in [('The Secret Garden','Frances Hodgson Burnett'),('Treasure Island','Robert Louis Stevenson')]:
    for n,title in enumerate(['A New Beginning','The Open Door'],1):
        target=root/'Audiobooks'/book/(f'{n:02d} - {title}.m4a');target.parent.mkdir(parents=True,exist_ok=True)
        if not target.exists(): subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-f','lavfi','-i','sine=frequency=150:duration=45','-af','volume=0.005','-metadata','title='+title,'-metadata','album='+book,'-metadata','artist='+author,'-metadata','genre=Classics','-metadata','track='+str(n),'-c:a','aac',str(target)],check=True)
print(root)
