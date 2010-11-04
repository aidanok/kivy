import os
from kivy import kivy_shader_dir
from kivy.logger import Logger
from kivy.resources import resource_find

from buffer cimport Buffer
from c_opengl cimport *

#TODO, see which ones we have to write in cython directlym e.g. transformations, texture etc.
from kivy.core.image import Image
import numpy
from kivy.lib.transformations import matrix_multiply, identity_matrix, \
             rotation_matrix, translation_matrix, scale_matrix


'''
standard math definitions
'''
cdef double pi = 3.1415926535897931
cdef extern from "math.h":
    double cos(double)
    double sin(double)
    double sqrt(double)

cdef struct vertex:
    GLfloat x, y
    GLfloat s0, t0 
    GLfloat s1, t1
    GLfloat s2, t2

cdef vertex vertex8f(GLfloat x, GLfloat y, GLfloat s0, GLfloat t0, GLfloat s1, GLfloat t1, GLfloat s2, GLfloat t2):
    cdef vertex v
    v.x  = x;   v.y  = y
    v.s0 = s0;  v.t0 = t0
    v.s1 = s1;  v.t1 = t1
    v.s2 = s2;  v.t2 = t2
    return v

cdef vertex vertex6f(GLfloat x, GLfloat y, GLfloat s0, GLfloat t0, GLfloat s1, GLfloat t1):
    return vertex8f(x,y,s0,t0,s1,t1,0.0,0.0)

cdef vertex vertex4f(GLfloat x, GLfloat y, GLfloat s0, GLfloat t0):
    return vertex8f(x,y,s0,t0,0.0,0.0,0.0,0.0)
    
cdef vertex vertex2f(GLfloat x, GLfloat y):
    return vertex8f(x,y,0.0,0.0,0.0,0.0,0.0,0.0)

'''
Description of vertex attributes, standard format for shaders and vbo
'''
cdef list VERTEX_ATTRIBUTES = [ 
    {'name': 'vPosition',  'index':0, 'size': 2, 'type': GL_FLOAT, 'bytesize': sizeof(GLfloat)*2, 'per_vertex': True},
    {'name': 'vTexCoord0', 'index':1, 'size': 2, 'type': GL_FLOAT, 'bytesize': sizeof(GLfloat)*2, 'per_vertex': True},
    {'name': 'vTexCoord1', 'index':2, 'size': 2, 'type': GL_FLOAT, 'bytesize': sizeof(GLfloat)*2, 'per_vertex': True}, 
    {'name': 'vTexCoord2', 'index':3, 'size': 2, 'type': GL_FLOAT, 'bytesize': sizeof(GLfloat)*2, 'per_vertex': True}, 
    {'name': 'vColor',     'index':4, 'size': 4, 'type': GL_FLOAT, 'bytesize': sizeof(GLfloat)*4, 'per_vertex': False} 
] 




cdef class GraphicContext
cdef int ACTIVE_SHADER = 0
cdef GraphicContext _default_context = None



cdef class Shader:
    '''Create a vertex or fragment shader

    :Parameters:
        `vert_src` : string 
            source code for vertex shader
        `frag_src` : string
            source code for fragment shader
    '''
    cdef int program
    cdef int vertex_shader
    cdef int fragment_shader
    cdef object vert_src
    cdef object frag_src 
    cdef dict uniform_locations 
    cdef dict uniform_values

    def __cinit__(self):
        self.uniform_locations = dict()
        self.uniform_values = dict()

    def __init__(self, str vert_src, str frag_src):
        self.frag_src = frag_src
        self.vert_src = vert_src
        self.program = glCreateProgram()
        self.bind_attrib_locations()
        self.build()
        
    cdef int get_uniform_loc(self, str name):
        name_byte_str = name
        cdef char* c_name = name_byte_str
        cdef int loc = glGetUniformLocation(self.program, c_name)
        self.uniform_locations[name] = loc
        return loc

    #def __setitem__(self, str name, value):
    cpdef set_uniform(self, str name, value):
        self.uniform_values[name] = value

    cpdef upload_uniform(self, str name, value):
        """pass a uniform variable to the shader"""
        cdef int vec_size, loc
        val_type = type(value)        
        loc = self.uniform_locations.get(name, self.get_uniform_loc(name))
    

        #TODO: use cython matrix transforms
        if val_type == numpy.ndarray:
            self.set_uniform_matrix(name, value)
        elif val_type == int:
            glUniform1i(loc, value)
        elif val_type == float:
            glUniform1f(loc, value)
        else:  
            #must have been a list, tuple, or other sequnce ot be a vector uniform
            val_type = type(value[0])
            vec_size = len(value)
            if val_type == float:
                if vec_size == 2:
                    glUniform2f(loc, value[0], value[1])
                elif vec_size == 3:
                    glUniform3f(loc, value[0], value[1], value[2])
                elif vec_size == 4:
                    glUniform4f(loc, value[0], value[1], value[2], value[3])
            elif val_type == int:
                if vec_size == 2:
                    glUniform2i(loc, value[0], value[1])
                elif vec_size == 3:
                    glUniform3i(loc, value[0], value[1], value[2])
                elif vec_size == 4:
                    glUniform4i(loc, value[0], value[1], value[2], value[3])       


    cdef set_uniform_matrix(self, str name, value):
        #TODO: use cython matrix transforms
        cdef int loc = self.uniform_locations.get(name, self.get_uniform_loc(name))
        cdef GLfloat mat[16] 
        np_flat = numpy.ascontiguousarray(value.T, dtype='float32').flatten()
        for i in range(16):
            mat[i] = <GLfloat>np_flat[i]
        glUniformMatrix4fv(loc, 1, False, mat) 

    cpdef use(self):
        '''Use the shader'''
        if ACTIVE_SHADER == self.program:
            return
        glUseProgram(self.program)
        for k,v in self.uniform_values.iteritems():
            self.upload_uniform(k, v)
        
    cpdef stop(self):
        '''Stop using the shader'''
        glUseProgram(0)

    cdef bind_attrib_locations(self):
        cdef char* c_name
        for attr in VERTEX_ATTRIBUTES:
            c_name = attr['name']
            glBindAttribLocation(self.program, attr['index'], c_name)
            if attr['per_vertex']:
                glEnableVertexAttribArray(attr['index'])

    cdef build(self):
        self.vertex_shader = self.compile_shader(self.vert_src, GL_VERTEX_SHADER)
        self.fragment_shader = self.compile_shader(self.frag_src, GL_FRAGMENT_SHADER)
        glAttachShader(self.program, self.vertex_shader)
        glAttachShader(self.program, self.fragment_shader)
        glLinkProgram(self.program)
        self.uniform_locations = dict()
        self.process_build_log()

    cdef compile_shader(self, char* source, shadertype):
        shader = glCreateShader(shadertype)
        glShaderSource(shader, 1, <GLchar**> &source, NULL)
        glCompileShader(shader)
        return shader

    cdef get_shader_log(self, shader):
        '''Return the shader log'''
        cdef int msg_len
        cdef char msg[2048]
        glGetShaderInfoLog(shader, 2048, &msg_len, msg)
        return msg

    cdef get_program_log(self, shader):
        '''Return the program log'''
        cdef int msg_len
        cdef char msg[2048]
        glGetProgramInfoLog(shader, 2048, &msg_len, msg)
        return msg

    cdef process_build_log(self):
        message = self.get_program_log(self.program)
        if message:
            Logger.error('Shader: shader program message: %s' % message)
            raise Exception(message)
        else:
            Logger.debug('Shader compiled sucessfully')
    

cdef class GraphicContext:
    '''Handle the saving/restore of the context

    TODO: explain more how it works
    '''
    cdef dict state
    cdef list stack
    cdef set journal
    cdef readonly int need_flush
    cdef Shader _default_shader

    property default_shader:
        def __get__(self):
            if not self._default_shader:
                _default_vertex_shader = open(os.path.join(kivy_shader_dir, 'default.vs')).read()
                _default_fragment_shader = open(os.path.join(kivy_shader_dir, 'default.fs')).read()
                self._default_shader = Shader(_default_vertex_shader, _default_fragment_shader)
            return self._default_shader

    def __cinit__(self):
        self.state = {}
        self.stack = []
        self.journal = set()
        self.need_flush = 0
        self._default_shader = None

    def __init__(self):
        # create initial state
        self.reset()
        self.save()

    cpdef set(self, str key, value):
        self.state[key] = value
        self.journal.add(key)
        self.need_flush = 1

    cpdef get(self, str key):
        return self.state[key]

    cpdef reset(self):
        self.set('shader', self.default_shader)
        self.set('projection_mat', identity_matrix())
        self.set('modelview_mat', identity_matrix())
        self.set('color', (1.0, 1.0, 1.0, 1.0) )
        self.set('blend', 0)
        self.set('blend_sfactor', GL_SRC_ALPHA)
        self.set('blend_dfactor', GL_ONE_MINUS_SRC_ALPHA)
        self.set('linewidth', 1)
        #self.set('texture0', 0)

    cpdef save(self):
        self.stack.append(self.state.copy())

    cpdef restore(self):
        newstate = self.stack.pop()
        state = self.state
        for k, v in newstate.iteritems():
            if not state[k] is v:
                self.set(k, v)
    
    cpdef translate(self, double x, double y, double z):
        t = translation_matrix(x, y, z)
        mat = matrix_multiply(self.get('modelview_mat'), t)
        self.set('modelview_mat', mat)

    cpdef scale(self, double s):
        t = scale_matrix(s)
        mat = matrix_multiply(self.get('modelview_mat'), t)
        self.set('modelview_mat', mat)
        
    cpdef rotate(self, double angle, double x, double y, double z):
        t = rotation_matrix(angle, [x, y, z])
        mat = matrix_multiply(self.get('modelview_mat'), t)
        self.set('modelview_mat', mat)

    cpdef flush(self):
        # activate all the last changes done on context
        # apply all the actions in the journal !
        cdef dict state
        cdef set journal
        cdef str x

        self.state['shader'].use()
        
        if not self.journal:
            return

        state = self.state
        journal = self.journal
        for x in journal:
            value = state[x]
            if x == 'color':
                glVertexAttrib4f(4, value[0], value[1], value[2], value[3]) #vColor
            
            elif x == 'blend':
                if value:   glEnable(GL_BLEND)
                else:       glDisable(GL_BLEND)
            
            elif x in ('blend_sfactor', 'blend_dfactor'):
                glBlendFunc(state['blend_sfactor'], state['blend_dfactor'])
         
            elif x != 'shader': #set uniform variable
                #print "setting uniform", x, value
                self.state['shader'].set_uniform(x, value)

        journal.clear()
        self.need_flush = 0





cdef class VBO:
    cdef GLuint id
    cdef int usage
    cdef int target
    cdef list format
    cdef Buffer data
    cdef int need_upload
    cdef int vbo_size
    
    def __cinit__(self):
        self.usage  = GL_DYNAMIC_DRAW
        self.target = GL_ARRAY_BUFFER
        self.format = VERTEX_ATTRIBUTES
        self.need_upload = 1
        self.vbo_size = 0
    
    def __init__(self, **kwargs):
        self.format = kwargs.get('format', self.format)
        self.data = Buffer(sizeof(vertex))
        self.create_buffer()

    cdef create_buffer(self):
        glGenBuffers(1, &self.id)
        self.allocate_buffer()

    cdef allocate_buffer(self):
        self.vbo_size = self.data.size()
        glBindBuffer(GL_ARRAY_BUFFER, self.id)
        glBufferData(GL_ARRAY_BUFFER, self.vbo_size, self.data.pointer(), self.usage)
        self.need_upload = 0

    cdef update_buffer(self):
        if self.vbo_size < self.data.size():
            self.allocate_buffer()
        elif self.need_upload:
            glBindBuffer(GL_ARRAY_BUFFER, self.id)
            glBufferSubData(GL_ARRAY_BUFFER, 0, self.data.size(), self.data.pointer())
            self.need_upload  = 0

    cdef bind(self):
        self.update_buffer()
        glBindBuffer(GL_ARRAY_BUFFER, self.id)
        cdef int offset = 0
        for attr in self.format:
            if not attr['per_vertex']:
                continue
            glVertexAttribPointer(attr['index'], attr['size'], attr['type'], GL_FALSE, sizeof(vertex), <GLvoid*>offset)
            offset += attr['bytesize']

    cdef unbind(self):
        glBindBuffer(GL_ARRAY_BUFFER, 0)

    cdef add_vertices(self, void *v, int* indices, int count):
        self.need_upload = 1
        self.data.add(v, indices, count)

    cdef update_vertices(self, int index, vertex* v, int count):
        self.need_upload = 1
        self.data.update(index, v, count)
        
    cdef remove_vertices(self, int* indices, int count):
        self.data.remove(indices, count)






'''
Insruction type bitmask. Graphic Instruction Codes
    bitmask to hold various graphic intrcution codes so its 
    possible to set teh code on any GraphicInstruction
    in order to let the compiler know how to handle it best
'''
cdef int GI_NOOP         = 0x0000000
cdef int GI_IGNORE       = 0x0000001
cdef int GI_VERTEX_DATA  = 0x0000002
cdef int GI_CONTEXT_MOD  = 0x0000004




cdef class GraphicInstruction
cdef class VertexDataInstruction
cdef class Canvas
cdef Canvas ACTIVE_CANVAS = None

cdef class Canvas:
    cdef GraphicContext _context
    cdef VBO vertex_buffer
    cdef list texture_map
    cdef list batch

    #move to graphics compiler?:
    cdef int need_compile
    cdef int num_slices
    cdef list batch_slices

    def __cinit__(self):
        if _default_context == None:
            _default_context = GraphicContext()
        self._context = _default_context
        self.vertex_buffer = VBO()
        self.texture_map = []
        self.batch = []
        
        self.need_compile = 1
        self.batch_slices = []
        self.num_slices = 0


    property context:
        def __get__(self):
            return self._context

    cpdef __enter__(self):
        global ACTIVE_CANVAS
        ACTIVE_CANVAS = self

    cpdef __exit__(self, extype, value, traceback):
        global ACTIVE_CANVAS 
        ACTIVE_CANVAS = None

    cdef add(self, GraphicInstruction instruction):
        self.need_compile = 1
        self.batch.append(instruction)

    cdef update(self, instruction):
        ''' called by graphic instructions taht are part of teh canvas,
            when they have been changed in some way ''' 
        self.need_compile = 1

    cdef remove(self, element):
        pass

    cdef compile(self):
        with self:
            self.compile_run()

    cdef compile_init(self):
        self.texture_map = []
        self.batch_slices = []

    cdef compile_run(self):
        cdef GraphicInstruction item
        cdef int slice_start = -1
        cdef int slice_stop  = -1
        cdef int i, code

        self.compile_init()

        print "starting compile"

        for i in xrange(len(self.batch)):
            item = self.batch[i]
            code = item.CODE

            print "batch element CODE:", code

            #the instruction modifies teh context, so we cant combine the drawing
            #calls before and after it
            if code & GI_CONTEXT_MOD:
                print "context mod"
                #first compile the slices we been loopiing over which we can combine
                #from slice_start to slice_stop. (using compile_slice() )
                #add the context modifying instruction to batch_slices
                #reset slice start/stop index
                self.compile_slice('draw', slice_start, slice_stop)
                self.batch_slices.append(('instruction', item)) 
                slice_start = slice_stop = -1
            
            #the instruction pushes vertices to the pipeline and doesnt modify
            #teh context, so we can happily combine it with any prior or follwing
            #instructions that do teh same, just keep incrementing slice stop index
            #until we cant combine any more, then well call compile_slice()
            elif code & GI_VERTEX_DATA:
                print "Vertex data"
                slice_stop = i
                if slice_start == -1:
                    slice_start = i

        #maybe we ended on an slice of vartex data, whcih we didnt push yet
        self.compile_slice('draw', slice_start, slice_stop)



    cdef compile_slice(self, str command, slice_start, slice_end):
        print "compiling slice:", slice_start, slice_end, command
        cdef VertexDataInstruction item
        cdef Buffer b = Buffer(sizeof(GLint))
        cdef int tex_target = -1
        cdef int tex_id = -1
        cdef int v, i

        #check if we have a valid slice
        if slice_start == -1:
            print "nothign to compile..empty slice"
            return


        #loop pver all teh whole slice, and combine all instructions
        for item in self.batch[slice_start:slice_end+1]:  
            print "adding", item, "to batch_slice", item.num_elements
            # add the vertex indices to be drawn from this item
            for i in range(item.num_elements): 
                v = item.element_data[i]
                b.add(&v, NULL, 1)
                print "adding INDEX:", i, v

            #handle textures (should go somewhere else?, maybe set GI_CONTEXT_MOD FLAG ALSO?)
            if item.texture:
                print "texture attached, must split batch_slice"
                if item.texture.id == tex_id: #the same, sweet, keep going
                    print "texture already bound on context...no split after all"
                    continue
                elif item.texture.id != tex_id:  #nope..muts bind the new texture
                    print "bindign new texture", item.texture 
                    target = item.texture.target
                    tex_id = item.texture.id
                    self.batch_slices.append(('instruction', BindTexture(0, target, tex_id)))
                    self.batch_slices.append((command, b))
                    b = Buffer(sizeof(GLint))
            elif tex_id != -1: #no item.texture..must unbind bound_texture and start new slice
                print "unbinding previous bound tetxure"
                target = item.texture.target
                self.batch_slices.append(('instruction', UnbindTexture(0, target)))
                self.batch_slices.append((command, b))
                b = Buffer(sizeof(GLint))


        print "done compiling slice"
        if b.count() > 0:  # last slice, all done, only have to add if there is actually somethign in it
            print "adding last slice"
            self.batch_slices.append((command, b))


    cpdef draw(self): 
        cdef int i
        cdef Buffer b

        if self.need_compile:
            self.compile()
            print "Done Compiling", self.batch_slices
            self.need_compile = 0

        self.vertex_buffer.bind() 
        attr = VERTEX_ATTRIBUTES[0]
        glBindBuffer(GL_ARRAY_BUFFER, self.vertex_buffer.id)

        for command, item in self.batch_slices:
            #print command, item
            if command == 'draw':
                self.context.flush()
                b = item
                #print "drawing elements:", b.count()
                glDrawElements(GL_TRIANGLES, b.count(), GL_UNSIGNED_INT, b.pointer())
            elif command == 'instruction':
                item.apply()
                
        glUseProgram(0)








cdef class GraphicInstruction:
    cdef int CODE     #Graphic instruction op code
    cdef Canvas canvas  #canvas on which to operate


    def __init__(self, int code):
        '''
            Base class for all Graphi Instructions
            :Parameters:
            `code`, constant: instruction code for hinting teh compiler
                currently a combination of:
                    GI_NOOP
                    GI_IGNORE
                    GI_CONTEXT_MOD
                    GI_VERTEX_DATA
                    
        '''
        global ACTIVE_CANVAS
        self.CODE = code
        self.canvas = ACTIVE_CANVAS


cdef class ContextInstruction(GraphicInstruction):
    def __init__(self):  
        '''
           Abstract Base class for GraphicInstructions that modidifies the
           context.  (so that canvas/compiler can know about how to optimize)
        '''
        GraphicInstruction.__init__(self, GI_CONTEXT_MOD)
        
    def apply(self):
        pass



cdef class SetColor(ContextInstruction):
    #TODO:
    '''
     add blending "mode", so user can pass str or enum
     e.g.: 'normal', 'subtract', 'multiply', 'burn', 'dodge', etc
    '''    
    cdef int blend
    cdef int s_factor
    cdef int d_factor
    cdef tuple _color    
    
    def __init__(self, r, g, b, a, **kwargs):
        '''
        SetColor will change the color being used to draw in the context
        :Parameters:
            `color`, tuple : 3 or 4 tuple, or r,g,b [,a] color components
            `blend`, bool  : enable or disable blending
            `s_factor`, GLenum: source factor mode used for blending
            `d_factor`, GLenum: destination factor mode for blending
        '''
        ContextInstruction.__init__(self)
        self.color     = <tuple> kwargs.get('color', (1.0, 1.0, 1.0, 1.0))
        self.blend    =  <int> kwargs.get('blend', 0)
        self.s_factor =  <int> kwargs.get('s_factor', GL_SRC_ALPHA) 
        self.d_factor =  <int> kwargs.get('d_factor', GL_ONE_MINUS_SRC_ALPHA)
        self.canvas.add(self)
        
    def apply(self):
        cdef GraphicContext c = self.canvas.context
        cdef tuple col = self._color
        c.set('color', (col[0], col[1], col[2], col[3]))
        c.set('blend', self.blend)
        c.set('blend_sfactor', self.s_factor)
        c.set('blend_dfactor', self.d_factor)

    property color:
        def __get__(self):  
            return self.color
        def __set__(self, tuple c):    
            cdef int c_dim = len(c)
            if len(c) == 4:
                self._color = c
            else:
                self._color = (c[0], c[1], c[2], 1.0)




cdef class BindTexture(ContextInstruction):
    cdef int index
    cdef int target
    cdef int tex_id

    def __init__(self, int index, int target, int tex_id):
        '''
        BindTexture Graphic instruction:
            The BindTexture Instruction will bind a texture and enable
            GL_TEXTURE_2D for subsequent drawing.

        :Parameters:
            `index`, int: teh texture index to unbind, e.g. 0 for GL_TEXTURE0
            `texture`, Texture:  specifies teh texture to bind to teh given index 
        '''
        ContextInstruction.__init__(self)
        self.index  = index
        self.target = target
        self.tex_id = tex_id

    def apply(self): 
        glActiveTexture(GL_TEXTURE0+self.index)
        glEnable(self.target)
        glBindTexture(self.target, self.tex_id)
        self.canvas.context.set('texture0', 0)



cdef class UnbindTexture(ContextInstruction):
    cdef int index
    cdef int target

    def __init__(self, int index, int target):
        '''
        UnbindTexture Graphic instruction:
            The UnbindTexture Instruction will unbind any texture and
            disable the target for subsequent drawing.

        :Parameters:
            `index`, int: teh texture index to unbind, e.g. 0 for GL_TEXTURE0
            `target`, GLenum:  the target to disable.  e.g. GL_TEXTURE_2D           
        '''
        ContextInstruction.__init__(self)
        self.index  = index
        self.target = target

    def apply(self): 
        glActiveTexture(GL_TEXTURE0+self.index)
        glBindTexture(self.target, 0)
        glDisable(self.target)








cdef class VertexDataInstruction(GraphicInstruction): 
    #canvas, vbo and texture to use with this element
    cdef VBO vbo           
    cdef object _texture    
   
    #local vertex buffers and vbo index storage 
    cdef int     v_count   #vertex count
    cdef Buffer  v_buffer  #local buffer of vertex data
    cdef vertex* v_data  

    #local buffer of vertex indices on vbp
    cdef Buffer  i_buffer 
    cdef int*    i_data

    #indices to draw.  e.g. [1,2,3], will draw triangle:
    #  self.v_data[0], self.v_data[1], self.v_data[2]
    cdef int*    element_data
    cdef Buffer  element_buffer
    cdef int     num_elements  


    def __init__(self, **kwargs):
        '''
        VertexDataInstruction
        A VertexDataInstruction pushes vertices into teh graphics pipeline
        this class manages a vbo, allocating a set of vertices on teh vbo
        and can update the vbo data, when local changes have been made

        :Parameters:
            `texture`: The tetxure to be bound while drawing teh vertices

        '''
        GraphicInstruction.__init__(self, GI_VERTEX_DATA)
        self.vbo     = self.canvas.vertex_buffer
        self.v_count = 0 #no vertices to draw until initialized
        self._texture = kwargs.get('texture', None)

        print "VERTEX INIT", 

    cdef allocate_vertex_buffers(self, int num_verts):
        ''' For allocating and initializing vertes data buffers
            of this GraphicElement both locally and on VBO

            Allocates local vertex and index buffers to be able to 
            hold num_verts vertices.  adds teh vertices to the vbo
            associated with the elements canvas and sets vbo indices
            in i_data.  

            After calling the follwoing buffers will have enough room
            for num_verts: 

            self.vbo:  num_verts are added to teh canvas' VBO

            self.v_data : `vertex*`, vertex array with enough room for num_verts.
                           pointing to start of v_buffer, so you can set data
                           using indexing.  liek:  self.v_data[i] = <vertex> v

            self.i_data : 'int*', int array of size num_verts.  has vbo index of
                          vertex in v_data.  so self.i_data[i] is vbo index of 
                          self.v_buffer[i]  
        '''

        print "allocating vertex data:", num_verts
        #create vertex and index buffers
        self.v_buffer = Buffer(sizeof(vertex))
        self.i_buffer = Buffer(sizeof(GLint))

        #allocate enough room for vertex and index data
        self.v_count = num_verts
        self.v_buffer.grow(num_verts)
        self.i_buffer.grow(num_verts)

        #set data pointers to be able to index vertices and indices
        self.v_data = <vertex*>  self.v_buffer.pointer()
        self.i_data = <int*> self.i_buffer.pointer()

        #allocte on vbo and update indices with 
        print self.v_count, "ASASASASASASASASAS\n", num_verts, self.v_buffer.count()
        self.vbo.add_vertices(self.v_data, self.i_data, self.v_count)
        print "done allocating"


    property indices:
        '''
        `indecies` : this property is write only.  it determines, which of teh vertices 
                     from this object will be drawn by teh canvas.  if e.g. teh object 
                     has 4 vertices.  tehn setting vdi.indices = (0,1,2 2,4,0), will
                     draw two triangles corrosponding to the vertices stored in v_data
                     this function automatically converts teh indices from local to vbo indices 
        '''
        def __set__(self, tuple batch):
            #create element buffer for list of vbo indices to be drawn
            self.element_buffer = Buffer(sizeof(int))
            cdef int i, e
            print "setting indices!!"
            for i in xrange(len(batch)):
                e = batch[i]
                print "element:", e
                self.element_buffer.add(&self.i_data[e], NULL, 1)
            self.element_data = <int*> self.element_buffer.pointer()
            self.num_elements = self.element_buffer.count()
            #since we changed the list of vertices to draw, canvas must recompile 
            self.canvas.update(self)


    cdef update_vbo_data(self):
        '''
            updates teh vertex data stored on vbo to be same as local 
            needs to be called if you change v_data inside this element
        '''
        cdef vertex* vtx = self.v_data
        cdef int* idx    = self.i_data
        cdef int i
        print "updating vbo data:"
        for i in range(self.v_count): 
            print idx[i], vtx[i].x, vtx[i].y, vtx[i].s0, vtx[i].t0
            self.vbo.update_vertices(idx[i], &vtx[i], 1)     

    property texture:
        ''' set/get the texture to be bound while the vertices are being drawn'''
        def __get__(self):
            return self._texture
        def __set__(self, tex):
            self._texture = tex

 

cdef class Triangle(VertexDataInstruction):
    cdef float _points[6]
    cdef float _tex_coords[6]

    def __init__(self, **kwargs):
        VertexDataInstruction.__init__(self, **kwargs)
        self.allocate_vertex_buffers(3)
        self.points  = kwargs.get('points')
        self.tex_coords  = kwargs.get('tex_coords', self.points)
        self.indices = (0,1,2) 
        self.canvas.add(self)

    cdef build(self):
        cdef float *vc, *tc
        vc = self._points;  tc = self._tex_coords
        self.v_data[0] = vertex4f(vc[0], vc[1], tc[0], tc[1])
        self.v_data[1] = vertex4f(vc[2], vc[3], tc[2], tc[3])
        self.v_data[2] = vertex4f(vc[4], vc[5], tc[4], tc[5])
        self.update_vbo_data()

    property points:
        def __set__(self, points):
            cdef int i
            for i in range(6):
                self._points[i] = points[i]
            self.build()

        def __get__(self):
            cdef float *p = self._points
            return (p[0],p[1],p[2],p[3],p[4],p[5]) 

    property tex_coords:
        def __set__(self, coords):
            cdef int i
            for i in range(6):
                self._tex_coords[i] = coords[i]
            self.build()

        def __get__(self):
            cdef float *p = self._tex_coords
            return (p[0],p[1],p[2],p[3],p[4],p[5]) 


cdef class Rectangle(VertexDataInstruction):
    cdef float x, y      #position
    cdef float w, h      #size
    cdef float _tex_coords[8] 

    def __init__(self, **kwargs):       
        VertexDataInstruction.__init__(self, **kwargs)
        self.allocate_vertex_buffers(4)

        #get keyword args for configuring rectangle
        self.size = kwargs.get('size')
        self.pos  = kwargs.get('pos', (0,0))
        cdef tuple t_coords =  (0.0,0.0, 1.0,0.0, 1.0,1.0, 0.0,1.0)
        if self.texture:
            t_coords = self.texture.tex_coords
        self.tex_coords  = kwargs.get('tex_coords', t_coords)
        
        #tell VBO which triangles to draw using our vertices 
        self.indices = (0,1,2, 2,3,0) 
        self.canvas.add(self)

    cdef build(self):
        cdef float* tc = self._tex_coords
        cdef float x,y,w,h
        x = self.x; y=self.y; w = self.w; h = self.h
        self.v_data[0] = vertex4f(x,    y, tc[0], tc[1])
        self.v_data[1] = vertex4f(x+w,  y, tc[2], tc[3])
        self.v_data[2] = vertex4f(x+w, y+h, tc[4], tc[5])
        self.v_data[3] = vertex4f(x,   y+h, tc[6], tc[7])
        self.update_vbo_data()

    property pos:
        def __get__(self):
            return (self.x, self.y)
        def __set__(self, pos):
            self.x = pos[0]
            self.y = pos[1]
            self.build()
        
    property size:
        def __get__(self):
            return (self.w, self.h)
        def __set__(self, size):
            self.w = size[0]
            self.h = size[1]
            self.build()
 
    property tex_coords:
        def __get__(self):
            cdef float *p = self._tex_coords
            return (p[0],p[1],p[2],p[3],p[4],p[5],p[6],p[7]) 

        def __set__(self, coords):
            cdef int i
            print "setting textire coordinates:", coords
            for i in range(8):
                self._tex_coords[i] = coords[i]
            self.build()



cdef class BorderRectangle(VertexDataInstruction):
    cdef float x, y
    cdef float w, h
    cdef float _border[4]
    cdef float _tex_coords[8]

    def __init__(self, **kwargs):       
        #we have 16 vertices in BorderRectangle
        
        VertexDataInstruction.__init__(self, **kwargs)
        self.allocate_vertex_buffers(16)
        if not self.texture:
            raise AttributeError("BorderRectangle must have a texture!")
        else:
            self.texture = self._texture


        #get keyword args for configuring rectangle
        cdef tuple s = kwargs.get('size')
        cdef tuple p = kwargs.get('pos', (0,0))
        cdef tuple bv = kwargs.get('border', (10,10,10,10))
        cdef float* b = self._border
        b[0] = bv[0];  b[1]=bv[1];  b[2]=bv[2];  b[3]=bv[3];
        self.x = p[0]; self.y = p[1]
        self.w = s[0]; self.h = s[1]
       
        self.build()      


        #tell VBO which triangles to draw using our vertices 
        #two triangles per quad       
        '''
            v9---v8------v7----v6 
            |        b2        |
           v10  v15------v14   v5
            |    |        |    |
            |-b4-|        |-b1-|
            |    |        |    |
           v11  v12------v13   v4
            |        b0        |
            v0---v1------v2----v3
        '''
        self.indices = (
             0,  1, 12,    12, 11,  0,  #bottom left 
             1,  2, 13,    13, 12,  1,  #bottom middle 
             2,  3,  4,     4, 13,  2,  #bottom right 
            13,  4,  5,     5, 14, 13,   #center right 
            14,  5,  6,     6,  7, 14,   #top right 
            15, 14,  7,     7,  8, 15,   #top middle 
            10, 15,  8,     8,  9, 10,   #top left 
            11, 12, 15,    15, 10, 11,   #center left 
            12, 13, 14,    14, 15, 12)   #center middel 
        self.canvas.add(self)

    cdef build(self):
        #pos and size of border rectangle
        cdef float x,y,w,h
        x=self.x;  y=self.y; w=self.w;  h=self.h
        
        #width and heigth of texture in pixels, and tex coord space 
        cdef float tw, th, tcw, tch
        cdef float* tc = self._tex_coords
        tsize  = self.texture.size
        tw  = tsize[0]
        th  = tsize[1]
        tcw = tc[2] - tc[0]  #right - left
        tch = tc[7] - tc[1]  #top - bottom
        
        #calculate border offset in texture coord space 
        # border width(px)/texture width(px) *  tcoord width
        cdef float *b = self._border
        cdef float tb[4] #border offset in texture coordinate space
        tb[0] = b[0] / th*tch  
        tb[1] = b[1] / tw*tcw 
        tb[2] = b[2] / th*tch
        tb[3] = b[3] / tw*tcw

        #print "x,y,w,h:", x, y, w, h
        #print "texture|coord size:", tw, th, tcw, tch
        #print "border:", b[0], b[1], b[2], b[3]
        #print "texture border:", tb[0], tb[1], tb[2], tb[3]
       
         #horizontal and vertical sections
        cdef float hs[4]
        cdef float vs[4]
        hs[0] = x;            vs[0] = y
        hs[1] = x + b[3];     vs[1] = y + b[0]
        hs[2] = x + w - b[1]; vs[2] = y + h - b[2]
        hs[3] = x + w;        vs[3] = y + h
        
        cdef float ths[4]
        cdef float tvs[4] 
        ths[0] = tc[0];              tvs[0] = tc[1]
        ths[1] = tc[0] + tb[3];      tvs[1] = tc[1] + tb[0]
        ths[2] = tc[0] + tcw-tb[1];  tvs[2] = tc[1] + tch - tb[2]
        ths[3] = tc[0] + tcw;        tvs[3] = tc[1] + tch

        #set the vertex data
        cdef vertex* v = self.v_data
        #bottom row
        v[0] = vertex4f(hs[0], vs[0], ths[0], tvs[0])
        v[1] = vertex4f(hs[1], vs[0], ths[1], tvs[0])
        v[2] = vertex4f(hs[2], vs[0], ths[2], tvs[0])
        v[3] = vertex4f(hs[3], vs[0], ths[3], tvs[0])

        #bottom inner border row
        v[11] = vertex4f(hs[0], vs[1], ths[0], tvs[1])
        v[12] = vertex4f(hs[1], vs[1], ths[1], tvs[1])
        v[13] = vertex4f(hs[2], vs[1], ths[2], tvs[1])
        v[4]  = vertex4f(hs[3], vs[1], ths[3], tvs[1])

        #top inner border row
        v[10] = vertex4f(hs[0], vs[2], ths[0], tvs[2])
        v[15] = vertex4f(hs[1], vs[2], ths[1], tvs[2])
        v[14] = vertex4f(hs[2], vs[2], ths[2], tvs[2])
        v[5]  = vertex4f(hs[3], vs[2], ths[3], tvs[2])

        #top row
        v[9] = vertex4f(hs[0], vs[3], ths[0], tvs[3])
        v[8] = vertex4f(hs[1], vs[3], ths[1], tvs[3])
        v[7] = vertex4f(hs[2], vs[3], ths[2], tvs[3])
        v[6] = vertex4f(hs[3], vs[3], ths[3], tvs[3])
        
        #phew....all done
        self.update_vbo_data()



    property pos:
        def __get__(self):
            return (self.x, self.y)
        def __set__(self, pos):
            self.x = pos[0]
            self.y = pos[1]
            self.build()
        
    property size:
        def __get__(self):
            return (self.w, self.h)
        def __set__(self, size):
            print "setting size: ", size
            self.w = size[0]
            self.h = size[1]
            self.build()

    property border:
        def __get__(self):
            cdef float* b = self._border
            return (b[0], b[1], b[2], b[3])
        def __set__(self, b):
            cdef int i
            for i in xrange(4):
                self._border[i] = b[0] 
            self.build()

    property texture:
        def __get__(self):
            return self._texture
        def __set__(self, tex):
            if tex == None:
                return
            cdef int i
            self._texture = tex
            tcords = self.texture.tex_coords
            print "SETTINF texture coords:", tcords
            for i in range(8):
                self._tex_coords[i] = tcords[i] 
            self.build()


cdef class Path(VertexDataInstruction):
    cdef Buffer points
    cdef float pen_x, pen_y
    def __init__(self, **kwargs):
        self.points = Buffer(sizeof(vertex))



cdef ACTIVE_PATH = None

cdef class PathInstruction(GraphicInstruction):
    cdef Path path 
    cdef float pen_x, pen_y

    def __init__(self):
        global ACTIVE_PATH
        GraphicInstruction.__init__(self, GI_IGNORE) 
        if ACTIVE_PATH:
            self.path = ACTIVE_PATH

cdef class PathStart(PathInstruction): 
    def __init__(self, **kwargs):
        global ACTIVE_PATH
        PathInstruction.__init__(self)

        if ACTIVE_PATH != None: 
            raise Exception("Can't start a new path, before the currently starte done has been ended")
        ACTIVE_PATH = self.path = Path()

        cdef tuple pos = kwargs.get('pos', (0.0, 0.0))
        self.path.pen_x = pos[0]
        self.path.pen_y = pos[1]

cdef class PathMoveTo(PathInstruction):
    def __init__(self, x, y): 
        PathInstruction.__init__(self) 
        self.path.pen_x = x
        self.path.pen_y = y


cdef class PathLineTo(PathInstruction):
    def __init__(self, x, y): 
        PathInstruction.__init__(self) 
        self.path.pen_x = x
        self.path.pen_y = y
