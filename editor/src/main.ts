import './style.css'
import { start } from './app'

const scroller = document.getElementById('editor')
if (!scroller) throw new Error('index.html has no #editor element')
start(scroller)
