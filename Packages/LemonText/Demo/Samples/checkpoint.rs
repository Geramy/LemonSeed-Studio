//! Copy-on-write checkpoints of files touched by an agent turn.
use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Checkpoint {
    pub id: u64,
    pub files: BTreeMap<PathBuf, Vec<u8>>,
}

#[derive(Debug, thiserror::Error)]
pub enum CheckpointError {
    #[error("path escapes the workspace: {0}")]
    OutsideWorkspace(PathBuf),
    #[error(transparent)]
    Io(#[from] io::Error),
}

pub struct Checkpoints<'a> {
    root: &'a Path,
    history: Vec<Checkpoint>,
}

impl<'a> Checkpoints<'a> {
    pub fn new(root: &'a Path) -> Self {
        Self { root, history: Vec::new() }
    }

    pub fn capture<I, P>(&mut self, paths: I) -> Result<u64, CheckpointError>
    where
        I: IntoIterator<Item = P>,
        P: AsRef<Path>,
    {
        let mut files = BTreeMap::new();
        for path in paths {
            let full = self.root.join(path.as_ref()).canonicalize()?;
            if !full.starts_with(self.root) {
                return Err(CheckpointError::OutsideWorkspace(full));
            }
            files.insert(full.clone(), fs::read(&full)?);
        }
        let id = self.history.last().map_or(1, |c| c.id + 1);
        self.history.push(Checkpoint { id, files });
        Ok(id)
    }

    pub fn restore(&self, id: u64) -> Result<usize, CheckpointError> {
        let Some(checkpoint) = self.history.iter().find(|c| c.id == id) else {
            return Ok(0);
        };
        for (path, bytes) in &checkpoint.files {
            fs::write(path, bytes)?;
        }
        Ok(checkpoint.files.len())
    }
}
