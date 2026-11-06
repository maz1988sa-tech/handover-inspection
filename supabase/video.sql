-- Videos on observations (fourth change). Clips go straight to storage through a one-time signed upload URL
-- that the hi-photo function hands to the owner; the poster frame is stored next to it as <id>.jpg.
update storage.buckets set file_size_limit = 52428800,
  allowed_mime_types = array['image/jpeg','image/png','image/webp','video/mp4','video/quicktime','video/webm']
where id = 'handover-photos';
